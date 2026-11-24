// Trailers (owner request: "feel like a popular streaming service"): the panel's YouTube trailer plays in YouTube's
// own embedded player inside a web view (webview_flutter; libmpv can't play YouTube without yt-dlp, which phones
// don't have). On a movie's or series' page it starts muted behind the title after a moment, like the streaming
// apps; the Trailer button plays it full screen with sound. Linux has no web view: the button opens the browser.
// YouTube refuses embeds that come without a referrer (its error 153), so the page is loaded with gerdTV's own
// origin and the iframe asks for strict-origin-when-cross-origin; if YouTube still refuses or the video is gone,
// the IFrame API's onError reaches us and the muted preview gives way to the backdrop again.
// Debugging: a black preview that never starts means the embed was refused; the full-screen view shows YouTube's
// own error number (150/101: the owner of the video doesn't allow embedding; 153: no referrer arrived).

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../l10n/gen/app_localizations.dart';
import 'update_settings.dart' show openOrShow;

/// Whether trailers can play inside the app (webview_flutter's platforms).
bool get trailersInApp =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// The trailer's page on YouTube (Linux, and the full-screen view's way out).
String trailerUrl(String id) => 'https://www.youtube.com/watch?v=$id';

/// The page the web view loads: YouTube's IFrame API player filling the view. [muted] previews loop without
/// controls; otherwise it plays once with sound and YouTube's controls. Errors go to the `Trailer` channel.
String trailerHtml(String id, {required bool muted}) {
  final vars = muted
      ? "{autoplay: 1, mute: 1, controls: 0, loop: 1, playlist: '$id', playsinline: 1, rel: 0}"
      : "{autoplay: 1, mute: 0, controls: 1, playsinline: 1, rel: 0}";
  return '''<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:fixed;inset:0;width:100%;height:100%}</style>
</head><body><div id="p"></div>
<script src="https://www.youtube.com/iframe_api"></script>
<script>
function onYouTubeIframeAPIReady() {
  new YT.Player('p', {
    videoId: '$id', host: 'https://www.youtube-nocookie.com', playerVars: $vars,
    events: { onError: function (e) { Trailer.postMessage('error ' + e.data); } }
  });
}
</script></body></html>''';
}

/// gerdTV's origin for the embed (YouTube wants a referrer; any https origin of the app's own will do).
const _origin = 'https://world.zakis.gerdtv/';

/// A web view playing the trailer [id]; [onError] when YouTube refuses it or it can't be found.
class TrailerView extends StatefulWidget {
  const TrailerView({
    super.key,
    required this.id,
    required this.muted,
    this.onError,
  });
  final String id;
  final bool muted;
  final ValueChanged<String>? onError;

  @override
  State<TrailerView> createState() => _TrailerViewState();
}

class _TrailerViewState extends State<TrailerView> {
  late final WebViewController _web = _controller();

  WebViewController _controller() {
    // Autoplay without a tap: iOS/macOS and Android both ask for a user gesture by default.
    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
          )
        : const PlatformWebViewControllerCreationParams();
    final web = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Trailer',
        onMessageReceived: (m) => widget.onError?.call(m.message),
      );
    // macOS's web view has no background colour ("opaque is not implemented on macOS"); the page itself is black.
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      web.setBackgroundColor(Colors.black);
    }
    final android = web.platform;
    if (android is AndroidWebViewController) {
      android.setMediaPlaybackRequiresUserGesture(false);
    }
    web.loadHtmlString(
      trailerHtml(widget.id, muted: widget.muted),
      baseUrl: _origin,
    );
    return web;
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}

/// The Trailer button's action: full screen with sound in the app, or the browser where there is no web view.
Future<void> playTrailer(BuildContext context, String id) async {
  if (!trailersInApp) return openOrShow(context, trailerUrl(id));
  await Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => _TrailerScreen(id: id)));
}

class _TrailerScreen extends StatelessWidget {
  const _TrailerScreen({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(l10n.trailer),
        actions: [
          // YouTube's own app or the browser, e.g. when the owner of the video doesn't allow embedding.
          IconButton(
            key: const Key('trailer.youtube'),
            tooltip: l10n.trailerOnYouTube,
            icon: const Icon(Icons.open_in_new),
            onPressed: () => openOrShow(context, trailerUrl(id)),
          ),
        ],
      ),
      body: TrailerView(id: id, muted: false),
    );
  }
}
