import 'package:hisvpn/enum/enum.dart';
import 'package:hisvpn/l10n/l10n.dart';

extension ProviderSourceExt on ProviderSource {
  String label(AppLocalizations appLocalizations) => switch (this) {
    ProviderSource.subscription => appLocalizations.providerSourceSubscription,
    ProviderSource.profile => appLocalizations.profile,
    ProviderSource.app => appLocalizations.app,
  };
}
