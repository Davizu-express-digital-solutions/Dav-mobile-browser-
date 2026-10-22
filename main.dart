import 'dart:convert';
import 'dart:io' show HttpClient;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const DavApp());

const String kHome = 'https://www.google.com';
const String kSearch = 'https://www.google.com/search?q=';

/// Turns whatever the user typed into a loadable URL.
/// URLs get loaded, everything else becomes a Google search.
String resolveInput(String raw, {required bool httpsOnly}) {
  final text = raw.trim();
  if (text.isEmpty) return kHome;

  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(text);
  if (hasScheme) {
    if (httpsOnly && text.startsWith('http://')) {
      return text.replaceFirst('http://', 'https://');
    }
    return text;
  }

  final looksLikeHost =
      !text.contains(' ') && (text.contains('.') || text.startsWith('localhost'));
  if (looksLikeHost) return 'https://$text';

  return kSearch + Uri.encodeQueryComponent(text);
}

/// Bookmarks, history and settings are kept in the platform's secure storage:
/// Android Keystore-backed encrypted preferences / iOS Keychain.
class Store {
  static const _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static Future<List<Map<String, String>>> load(String key) async {
    try {
      final raw = await _s.read(key: key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(String key, List<Map<String, String>> value) async {
    try {
      await _s.write(key: key, value: jsonEncode(value));
    } catch (_) {}
  }

  static Future<bool> readBool(String key, bool fallback) async {
    try {
      final raw = await _s.read(key: key);
      if (raw == null) return fallback;
      return raw == 'true';
    } catch (_) {
      return fallback;
    }
  }

  static Future<void> writeBool(String key, bool value) async {
    try {
      await _s.write(key: key, value: value.toString());
    } catch (_) {}
  }
}

/// The build workflow replaces OWNER/REPO with your real GitHub repository.
const String kUpdateRepo = 'OWNER/REPO';

class UpdateInfo {
  UpdateInfo(this.version, this.build, this.url);
  final String version;
  final int build;
  final String url;
}

/// Looks at the newest GitHub release and reports it if it is newer than
/// the installed app. Returns null when the app is already up to date.
/// Throws when the check itself fails (no internet, no release, etc).
class Updater {
  static Future<UpdateInfo?> check() async {
    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;

    final client = HttpClient()..userAgent = 'DavBrowser';
    try {
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases/latest'),
      );
      req.headers.set('Accept', 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('Update check failed: ${res.statusCode}');
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final build = int.tryParse(tag.split('.').last) ?? 0;

      String? url;
      for (final a in (json['assets'] as List? ?? [])) {
        final name = (a['name'] as String?) ?? '';
        if (name.endsWith('.apk')) {
          url = a['browser_download_url'] as String?;
          break;
        }
      }

      if (url == null || build <= current) return null;
      return UpdateInfo(tag.replaceFirst('v', ''), build, url);
    } finally {
      client.close();
    }
  }
}

class DavApp extends StatelessWidget {
  const DavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dav',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      home: const BrowserHome(),
    );
  }
}

class BrowserTab {
  BrowserTab({
    required this.incognito,
    required this.httpsOnly,
    required this.onUpdate,
    required this.onVisit,
    String? initialUrl,
  }) : url = initialUrl ?? kHome {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (req) {
            if (httpsOnly() && req.url.startsWith('http://')) {
              controller.loadRequest(
                Uri.parse(req.url.replaceFirst('http://', 'https://')),
              );
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageStarted: (u) {
            url = u;
            progress = 0;
            onUpdate();
          },
          onProgress: (p) {
            progress = p;
            onUpdate();
          },
          onPageFinished: (u) async {
            url = u;
            progress = 100;
            title = await controller.getTitle() ?? u;
            canBack = await controller.canGoBack();
            canForward = await controller.canGoForward();
            if (!incognito) onVisit(title, u);
            onUpdate();
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  final bool incognito;
  final bool Function() httpsOnly;
  final VoidCallback onUpdate;
  final void Function(String title, String url) onVisit;

  late final WebViewController controller;
  String url;
  String title = '';
  int progress = 0;
  bool canBack = false;
  bool canForward = false;

  Future<void> wipe() async {
    await controller.clearCache();
    await controller.clearLocalStorage();
  }
}

class BrowserHome extends StatefulWidget {
  const BrowserHome({super.key});

  @override
  State<BrowserHome> createState() => _BrowserHomeState();
}

class _BrowserHomeState extends State<BrowserHome> {
  final List<BrowserTab> tabs = [];
  final List<Map<String, String>> bookmarks = [];
  final List<Map<String, String>> history = [];
  int current = 0;
  bool httpsOnly = true;

  final TextEditingController urlCtl = TextEditingController();
  final FocusNode focus = FocusNode();

  BrowserTab get tab => tabs[current];

  @override
  void initState() {
    super.initState();
    tabs.add(_newTab());
    focus.addListener(() {
      if (!focus.hasFocus && mounted) setState(_syncUrlBar);
    });
    _load();
    Future.delayed(const Duration(seconds: 3), () => _checkForUpdate());
  }

  @override
  void dispose() {
    urlCtl.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final b = await Store.load('bookmarks');
    final h = await Store.load('history');
    final s = await Store.readBool('httpsOnly', true);
    if (!mounted) return;
    setState(() {
      bookmarks
        ..clear()
        ..addAll(b);
      history
        ..clear()
        ..addAll(h);
      httpsOnly = s;
    });
  }

  BrowserTab _newTab({bool incognito = false, String? url}) {
    return BrowserTab(
      incognito: incognito,
      initialUrl: url,
      httpsOnly: () => httpsOnly,
      onUpdate: () {
        if (mounted) setState(_syncUrlBar);
      },
      onVisit: _onVisit,
    );
  }

  void _syncUrlBar() {
    if (tabs.isEmpty || focus.hasFocus) return;
    urlCtl.text = tab.url;
  }

  void _onVisit(String title, String url) {
    if (history.isNotEmpty && history.first['url'] == url) return;
    history.insert(0, {'title': title, 'url': url});
    if (history.length > 200) history.removeRange(200, history.length);
    Store.save('history', history);
  }

  void _addTab({bool incognito = false}) {
    setState(() {
      tabs.add(_newTab(incognito: incognito));
      current = tabs.length - 1;
      _syncUrlBar();
    });
  }

  Future<void> _closeTab(int i) async {
    final t = tabs[i];
    setState(() {
      tabs.removeAt(i);
      if (tabs.isEmpty) {
        tabs.add(_newTab());
        current = 0;
      } else {
        if (i < current) current--;
        if (current >= tabs.length) current = tabs.length - 1;
      }
      _syncUrlBar();
    });
    if (t.incognito) {
      await t.wipe();
      if (!tabs.any((x) => x.incognito)) {
        await WebViewCookieManager().clearCookies();
      }
    }
  }

  void _go(String text) {
    focus.unfocus();
    tab.controller.loadRequest(
      Uri.parse(resolveInput(text, httpsOnly: httpsOnly)),
    );
  }

  void _toggleBookmark() {
    final t = tab;
    final idx = bookmarks.indexWhere((b) => b['url'] == t.url);
    setState(() {
      if (idx >= 0) {
        bookmarks.removeAt(idx);
      } else {
        bookmarks.insert(0, {
          'title': t.title.isEmpty ? t.url : t.title,
          'url': t.url,
        });
      }
    });
    Store.save('bookmarks', bookmarks);
  }

  Future<void> _clearData() async {
    history.clear();
    await Store.save('history', history);
    await WebViewCookieManager().clearCookies();
    for (final t in tabs) {
      await t.controller.clearCache();
      await t.controller.clearLocalStorage();
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Browsing data cleared')),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _checkForUpdate({bool manual = false}) async {
    try {
      final u = await Updater.check();
      if (!mounted) return;
      if (u == null) {
        if (manual) _snack('You already have the latest version');
        return;
      }
      _askUpdate(u);
    } catch (_) {
      if (manual) {
        _snack("Couldn't check for updates. Please check your internet.");
      }
    }
  }

  void _askUpdate(UpdateInfo u) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Text('Dav Browser ${u.version} is ready. Update now?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadAndInstall(u);
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  void _downloadAndInstall(UpdateInfo u) {
    final progress = ValueNotifier<String>('Starting download...');
    var open = true;

    void close() {
      if (open && mounted) {
        open = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Updating Dav Browser'),
        content: ValueListenableBuilder<String>(
          valueListenable: progress,
          builder: (_, value, __) => Text(value),
        ),
      ),
    );

    OtaUpdate()
        .execute(u.url, destinationFilename: 'dav_browser_update.apk')
        .listen(
      (event) {
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            progress.value = 'Downloading ${event.value ?? 0}%';
          case OtaStatus.INSTALLING:
            close();
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
            close();
            _snack(
              'Allow "Install unknown apps" for Dav Browser in Android settings, then try again.',
            );
          default:
            close();
            if (event.status != OtaStatus.INSTALLATION_DONE) {
              _snack('Update failed. Please try again later.');
            }
        }
      },
      onError: (_) {
        close();
        _snack('Update failed. Please try again later.');
      },
    );
  }

  void _showTabs() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Text(
                      'Tabs (${tabs.length})',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('New'),
                      onPressed: () {
                        _addTab();
                        Navigator.pop(ctx);
                      },
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.visibility_off),
                      label: const Text('Private'),
                      onPressed: () {
                        _addTab(incognito: true);
                        Navigator.pop(ctx);
                      },
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: tabs.length,
                  itemBuilder: (_, i) {
                    final t = tabs[i];
                    return ListTile(
                      selected: i == current,
                      leading: Icon(
                        t.incognito ? Icons.visibility_off : Icons.public,
                      ),
                      title: Text(
                        t.title.isEmpty ? t.url : t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        t.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          await _closeTab(i);
                          setSheet(() {});
                        },
                      ),
                      onTap: () {
                        setState(() {
                          current = i;
                          _syncUrlBar();
                        });
                        Navigator.pop(ctx);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showList(String title, List<Map<String, String>> items, String key) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: Column(
              children: [
                ListTile(
                  title: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                  trailing: TextButton(
                    onPressed: () {
                      items.clear();
                      Store.save(key, items);
                      setSheet(() {});
                    },
                    child: const Text('Clear all'),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('Nothing here yet'))
                      : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final it = items[i];
                            return ListTile(
                              title: Text(
                                it['title'] ?? it['url']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                it['url']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                tab.controller.loadRequest(Uri.parse(it['url']!));
                              },
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () {
                                  items.removeAt(i);
                                  Store.save(key, items);
                                  setSheet(() {});
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleBack() async {
    if (await tab.controller.canGoBack()) {
      await tab.controller.goBack();
    } else if (tabs.length > 1) {
      await _closeTab(current);
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tab;
    final secure = t.url.startsWith('https://');
    final bookmarked = bookmarks.any((b) => b['url'] == t.url);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: urlCtl,
                        focusNode: focus,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        autocorrect: false,
                        enableSuggestions: false,
                        onSubmitted: _go,
                        onTap: () => urlCtl.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: urlCtl.text.length,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          filled: true,
                          hintText: 'Search Google or type a URL',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: Icon(
                            t.incognito
                                ? Icons.visibility_off
                                : (secure ? Icons.lock : Icons.lock_open),
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        switch (v) {
                          case 'new':
                            _addTab();
                          case 'private':
                            _addTab(incognito: true);
                          case 'bookmarks':
                            _showList('Bookmarks', bookmarks, 'bookmarks');
                          case 'history':
                            _showList('History', history, 'history');
                          case 'https':
                            setState(() => httpsOnly = !httpsOnly);
                            Store.writeBool('httpsOnly', httpsOnly);
                          case 'clear':
                            await _clearData();
                          case 'update':
                            await _checkForUpdate(manual: true);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'new', child: Text('New tab')),
                        const PopupMenuItem(
                          value: 'private',
                          child: Text('New private tab'),
                        ),
                        const PopupMenuItem(
                          value: 'bookmarks',
                          child: Text('Bookmarks'),
                        ),
                        const PopupMenuItem(
                          value: 'history',
                          child: Text('History'),
                        ),
                        CheckedPopupMenuItem(
                          value: 'https',
                          checked: httpsOnly,
                          child: const Text('HTTPS-only mode'),
                        ),
                        const PopupMenuItem(
                          value: 'clear',
                          child: Text('Clear browsing data'),
                        ),
                        const PopupMenuItem(
                          value: 'update',
                          child: Text('Check for updates'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              t.progress < 100
                  ? LinearProgressIndicator(value: t.progress / 100, minHeight: 2)
                  : const SizedBox(height: 2),
              Expanded(
                child: WebViewWidget(key: ObjectKey(t), controller: t.controller),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: t.canBack ? () => t.controller.goBack() : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: t.canForward ? () => t.controller.goForward() : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => t.controller.reload(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.home_outlined),
                    onPressed: () => t.controller.loadRequest(Uri.parse(kHome)),
                  ),
                  IconButton(
                    icon: Icon(bookmarked ? Icons.star : Icons.star_border),
                    onPressed: _toggleBookmark,
                  ),
                  IconButton(
                    icon: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.onSurface,
                          width: 1.5,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${tabs.length}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    onPressed: _showTabs,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
