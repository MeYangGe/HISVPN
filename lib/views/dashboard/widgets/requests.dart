import 'package:hisvpn/common/common.dart';
import 'package:hisvpn/enum/enum.dart';
import 'package:hisvpn/icons/icons.dart';
import 'package:hisvpn/providers/app.dart';
import 'package:hisvpn/views/connection/requests.dart';
import 'package:hisvpn/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'feed_card.dart';

class RequestsCard extends StatelessWidget {
  const RequestsCard({super.key});

  void _openRequests(BuildContext context) {
    showSnapSheet(
      context,
      initialScrollOffset: double.maxFinite,
      builder: (_, controller) => RequestsView(scrollController: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FeedCard(
      label: PageLabel.requests.label,
      glyph: AppGlyphs.requests,
      onPressed: () => _openRequests(context),
      child: ThrottledFeedCount(provider: requestCountProvider),
    );
  }
}
