import 'package:hisvpn/common/network_error.dart';
import 'package:hisvpn/core/desktop/launch_policy.dart';
import 'package:hisvpn/core/method.dart';
import 'package:hisvpn/l10n/l10n.dart';

import 'dart:ui';

final currentAppLocalizations = AppLocalizations.current;

String? coreLaunchBlockedMessage(
  Object error,
  AppLocalizations appLocalizations,
) {
  if (!isPolicyBlockedLaunch(error)) {
    return null;
  }
  return switch (smartAppControlStateReader()) {
    SmartAppControlState.on || SmartAppControlState.evaluation =>
      appLocalizations.coreBlockedBySmartAppControlTip,
    _ => appLocalizations.coreBlockedByPolicyTip(launchOsError(error)!),
  };
}

String userFacingErrorMessage(Object error, AppLocalizations appLocalizations) {
  return networkErrorMessage(error, appLocalizations) ??
      coreLaunchBlockedMessage(error, appLocalizations) ??
      friendlyCoreErrorMessage(error, appLocalizations) ??
      switch (error) {
        CoreMethodException(:final message) => message,
        _ => error.toString(),
      };
}

/// The core surfaces proxy failures as mihomo's raw Go log lines ("context
/// deadline exceeded", "connection refused"...). Those are developer speak —
/// translate the known patterns into something a user can act on and keep
/// the raw text in the log page.
String? friendlyCoreErrorMessage(Object error, AppLocalizations appLocalizations) {
  final raw = switch (error) {
    CoreMethodException(:final message) => message,
    _ => error.toString(),
  };
  if (raw.isEmpty) {
    return null;
  }
  final lower = raw.toLowerCase();
  if (lower.contains('context deadline exceeded') || lower.contains('i/o timeout')) {
    return appLocalizations.coreErrorTimeout;
  }
  if (lower.contains('context canceled')) {
    return appLocalizations.coreErrorCancelled;
  }
  if (lower.contains('connection refused') ||
      lower.contains('no such host') ||
      lower.contains('connection reset') ||
      lower.contains('unexpected eof') ||
      lower.contains('broken pipe')) {
    return appLocalizations.coreErrorUnreachable;
  }
  return null;
}

Locale? getLocaleForString(String? localString) {
  if (localString == null) return null;
  final localSplit = localString.split('_');
  if (localSplit.length == 1) {
    return Locale(localSplit[0]);
  }
  if (localSplit.length == 2) {
    return Locale(localSplit[0], localSplit[1]);
  }
  if (localSplit.length == 3) {
    return Locale.fromSubtags(
      languageCode: localSplit[0],
      scriptCode: localSplit[1],
      countryCode: localSplit[2],
    );
  }
  return null;
}
