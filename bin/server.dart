import 'dart:convert';
import 'dart:io';

import 'package:jira_api/jira_api.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';

final _router = Router()
  ..post('/check-credentials', _checkCredentialsHandler)
  ..post('/validate-jql', _validateQjlHandler)
  ..post('/check-story-points-field', _checkStoryPointsField)
  ..post('/stats', _statsHandler);

final errorLogs = File('logs/error_log.txt');

Future<void> _logError(
  error, {
  required Request request,
  required String requestBody,
}) async {
  request.change();

  await errorLogs.writeAsString(
    'ERROR:${DateTime.now()}:\t${request.method} ${request.url} \n'
    'body of request:\n'
    '$requestBody\n'
    'error:\n'
    '$error',
    mode: FileMode.append,
  );
}

Future<Response> _checkCredentialsHandler(Request req) async {
  final body = await req.readAsString();
  try {
    final map = jsonDecode(body);

    final jiraStats = JiraStats(
      user: map['user'],
      apiToken: map['token'],
      accountName: map['account'],
    );

    await jiraStats.initialize();

    final response = {'message': 'Credentials is valid'};

    return Response.ok(jsonEncode(response), headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
    });
  } on UnauthorizedException catch (_) {
    final response = {'message': 'Credentials is invalid'};

    return Response(400, body: jsonEncode(response), headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
    });
  } catch (e, stackTrace) {
    await _logError(e, request: req, requestBody: body);
    return Response.internalServerError(body: '$e\n$stackTrace');
  }
}

Future<Response> _validateQjlHandler(Request req) async {
  final body = await req.readAsString();
  try {
    final map = jsonDecode(body);

    final jiraStats = JiraStats(
      user: map['user'],
      apiToken: map['token'],
      accountName: map['account'],
    );

    await jiraStats.initialize();

    final errors = await jiraStats.validateJql(map['jql']);

    const headers = {
      HttpHeaders.contentTypeHeader: 'application/json',
    };

    if (errors.isEmpty) {
      final response = {
        'message': 'JQL is valid',
      };
      return Response.ok(jsonEncode(response), headers: headers);
    } else {
      final response = {
        'message': errors.first,
        'errors': {
          'jql': errors,
        },
      };
      return Response(400, body: jsonEncode(response), headers: headers);
    }
  } on UnauthorizedException catch (_) {
    final response = {'message': 'Credentials is invalid'};

    return Response(400, body: jsonEncode(response), headers: {
      HttpHeaders.contentTypeHeader: 'application/json',
    });
  } catch (e, stackTrace) {
    await _logError(e, request: req, requestBody: body);
    return Response.internalServerError(body: '$e\n$stackTrace');
  }
}

Future<Response> _checkStoryPointsField(Request req) async {
  const headers = {
    HttpHeaders.contentTypeHeader: 'application/json',
  };

  final body = await req.readAsString();
  try {
    final map = jsonDecode(body);

    final jiraStats = JiraStats(
      user: map['user'],
      apiToken: map['token'],
      accountName: map['account'],
    );

    await jiraStats.initialize();

    await jiraStats.validateStoryPoitnsField(map['field']);

    final response = {
      'message': 'Field is valid',
    };
    return Response.ok(jsonEncode(response), headers: headers);
  } on InvalidFieldTypeException catch (_) {
    final response = {'message': 'Field must be of type num'};

    return Response(400, body: jsonEncode(response), headers: headers);
  } on FieldNotFoundException catch (_) {
    final response = {'message': 'Field not found'};

    return Response(404, body: jsonEncode(response), headers: headers);
  } on UnauthorizedException catch (_) {
    final response = {'message': 'Credentials is invalid'};

    return Response(400, body: jsonEncode(response), headers: headers);
  } catch (e, stackTrace) {
    await _logError(e, request: req, requestBody: body);
    return Response.internalServerError(body: '$e\n$stackTrace');
  }
}

Future<Response> _statsHandler(Request req) async {
  const headers = {
    HttpHeaders.contentTypeHeader: 'application/json',
  };

  final body = await req.readAsString();
  try {
    final map = jsonDecode(body);

    final jiraStats = JiraStats(
      user: map['user'],
      apiToken: map['token'],
      accountName: map['account'],
    );

    await jiraStats.initialize();

    final stats = await jiraStats.getTotalEstimationByJql(
      map['jql'],
      storyPointEstimateField: map['field'],
      frequency: SerializableSamplingFrequency.fromMap(
          map['frequency'] ?? SamplingFrequency.eachWeek.toString()),
      weeksAgoCount: map['weeksAgoCount'] ?? 4,
    );

    return Response.ok(jsonEncode(stats.toMap()), headers: headers);
  } on InvalidFieldTypeException catch (_) {
    final response = {'message': 'Field must be of type num'};

    return Response(400, body: jsonEncode(response), headers: headers);
  } on FieldNotFoundException catch (_) {
    final response = {'message': 'Field not found'};

    return Response(404, body: jsonEncode(response), headers: headers);
  } on UnauthorizedException catch (_) {
    final response = {'message': 'Credentials is invalid'};

    return Response(400, body: jsonEncode(response), headers: headers);
  } catch (e, stackTrace) {
    await _logError(e, request: req, requestBody: body);
    return Response.internalServerError(body: '$e\n$stackTrace');
  }
}

void main(List<String> args) async {
  // Use any available host or container IP (usually `0.0.0.0`).
  final ip = InternetAddress.anyIPv4;

  final logs = File('logs/log.txt');

  if (!logs.existsSync()) {
    logs.createSync(recursive: true);
  }

  if (!errorLogs.existsSync()) {
    errorLogs.createSync(recursive: true);
  }

  // Configure a pipeline that logs requests.
  final handler =
      Pipeline().addMiddleware(corsHeaders()).addMiddleware(logRequests(
    logger: (message, isError) {
      if (isError) {
        logs.writeAsStringSync(
          'ERROR:$message\n',
          mode: FileMode.append,
        );
      } else {
        logs.writeAsStringSync(
          'INFO:$message\n',
          mode: FileMode.append,
        );
      }
    },
  )).addHandler(_router);

  // For running in containers, we respect the PORT environment variable.
  final port = int.parse(Platform.environment['PORT'] ?? '443');
  final server = await serve(
    handler,
    ip,
    port,
    securityContext: getSecurityContext(),
  );
  print('Server listening on port ${server.port}');
}

SecurityContext getSecurityContext() {
  return SecurityContext()
    ..useCertificateChain(
        '/etc/letsencrypt/live/jira.mishkov.space/fullchain.pem')
    ..usePrivateKey('/etc/letsencrypt/live/jira.mishkov.space/privkey.pem');
}
