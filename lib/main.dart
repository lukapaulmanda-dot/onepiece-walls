import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// These two values are filled in automatically by the build (build.yml).
const String kRepo = '__REPO__';
const String kBranch = '__BRANCH__';

const String kFolder = 'wallpapers';
const String kAppName = 'One Piece Walls';
const String kAlbum = 'One Piece Walls';
const MethodChannel kChannel = MethodChannel('opwalls/wallpaper');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpWallsApp());
}

// ---------------------------------------------------------------- data

class Wallpaper {
  final String path;
  final String name;
  final String section;
  final String weekLabel;
  final int weekNum;
  final String url;

  const Wallpaper({
    required this.path,
    required this.name,
    required this.section,
    required this.weekLabel,
    required this.weekNum,
    required this.url,
  });
}

String rawUrl(String path) {
  final segs = <String>[...kRepo.split('/'), kBranch, ...path.split('/')];
  return Uri(
    scheme: 'https',
    host: 'raw.githubusercontent.com',
    pathSegments: segs,
  ).toString();
}

String prettify(String s) {
  final words = s
      .split(RegExp(r'[-_\s]+'))
      .where((e) => e.isNotEmpty)
      .map((e) => e[0].toUpperCase() + e.substring(1))
      .toList();
  return words.isEmpty ? s : words.join(' ');
}

// Folder layout:
//   wallpapers/<section>/week-01/pic.jpg   (sections, e.g. luffy, zoro)
//   wallpapers/week-01/pic.jpg             (old layout -> section "General")
List<Wallpaper> wallpapersFromPaths(List<String> paths) {
  const exts = {'jpg', 'jpeg', 'png', 'webp'};
  final legacyWeek = RegExp(r'^week[\s_-]*\d+$', caseSensitive: false);
  final out = <Wallpaper>[];

  for (final p in paths) {
    final parts = p.split('/');
    if (parts.length < 2 || parts.first != kFolder) continue;
    final name = parts.last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || name.startsWith('.')) continue;
    if (!exts.contains(name.substring(dot + 1).toLowerCase())) continue;

    var section = 'General';
    var weekFolder = '';
    if (parts.length >= 4) {
      section = prettify(parts[1]);
      weekFolder = parts[2];
    } else if (parts.length == 3) {
      if (legacyWeek.hasMatch(parts[1])) {
        weekFolder = parts[1];
      } else {
        section = prettify(parts[1]);
      }
    }

    final m = RegExp(r'\d+').firstMatch(weekFolder);
    final n = m == null ? 0 : (int.tryParse(m.group(0)!) ?? 0);
    final label = n > 0 ? 'Week $n' : 'Other';

    out.add(Wallpaper(
      path: p,
      name: name,
      section: section,
      weekLabel: label,
      weekNum: n,
      url: rawUrl(p),
    ));
  }

  out.sort((a, b) {
    final c = b.weekNum.compareTo(a.weekNum);
    if (c != 0) return c;
    final s = a.section.compareTo(b.section);
    if (s != 0) return s;
    final l = a.weekLabel.compareTo(b.weekLabel);
    if (l != 0) return l;
    return a.name.compareTo(b.name);
  });
  return out;
}

class WallpaperRepo {
  static const String _pathsKey = 'paths_cache_v1';
  static const String _timeKey = 'paths_cache_time_v1';

  static Future<List<Wallpaper>> load({bool force = false}) async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? cached;
    try {
      final raw = prefs.getString(_pathsKey);
      if (raw != null) {
        cached = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      }
    } catch (_) {
      cached = null;
    }
    final savedAt = prefs.getInt(_timeKey) ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - savedAt;
    if (!force && cached != null && age < 10 * 60 * 1000) {
      return wallpapersFromPaths(cached);
    }

    try {
      final uri = Uri.parse(
          'https://api.github.com/repos/$kRepo/git/trees/$kBranch?recursive=1');
      final res = await http
          .get(uri, headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        throw Exception('Server replied ${res.statusCode}');
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tree = (data['tree'] as List?) ?? const [];
      final paths = <String>[];
      for (final item in tree) {
        if (item is Map && item['type'] == 'blob' && item['path'] != null) {
          paths.add(item['path'].toString());
        }
      }
      await prefs.setString(_pathsKey, jsonEncode(paths));
      await prefs.setInt(_timeKey, DateTime.now().millisecondsSinceEpoch);
      return wallpapersFromPaths(paths);
    } catch (e) {
      if (cached != null) return wallpapersFromPaths(cached);
      rethrow;
    }
  }
}

class FavStore extends ChangeNotifier {
  final Set<String> _paths = <String>{};

  bool has(String p) => _paths.contains(p);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _paths
        ..clear()
        ..addAll(prefs.getStringList('favs') ?? const <String>[]);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> toggle(String p) async {
    if (!_paths.remove(p)) _paths.add(p);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('favs', _paths.toList());
    } catch (_) {}
  }
}

final FavStore favStore = FavStore();

String friendlyError(Object e) {
  if (e is PlatformException) return e.message ?? e.code;
  if (e is SocketException) return 'No internet connection';
  if (e is TimeoutException) return 'Connection timed out';
  return e.toString().replaceFirst('Exception: ', '');
}

Future<File> fetchToTemp(Wallpaper w) async {
  final dir = await getTemporaryDirectory();
  final dot = w.name.lastIndexOf('.');
  final ext = dot >= 0 ? w.name.substring(dot + 1).toLowerCase() : 'jpg';
  final file = File('${dir.path}/wall_${w.path.hashCode.abs()}.$ext');
  if (await file.exists() && await file.length() > 0) return file;
  final res =
      await http.get(Uri.parse(w.url)).timeout(const Duration(seconds: 90));
  if (res.statusCode != 200) {
    throw Exception('Download failed (${res.statusCode})');
  }
  await file.writeAsBytes(res.bodyBytes, flush: true);
  return file;
}

// ---------------------------------------------------------------- app

class OpWallsApp extends StatelessWidget {
  const OpWallsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE53935),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0E0E12),
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  List<Wallpaper> _all = const [];
  bool _loading = true;
  String? _error;
  String _selectedSection = 'All';
  String _selectedWeek = 'All';

  @override
  void initState() {
    super.initState();
    favStore.load();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    if (mounted) {
      setState(() {
        _loading = _all.isEmpty;
        _error = null;
      });
    }
    try {
      final list = await WallpaperRepo.load(force: force);
      if (!mounted) return;
      setState(() {
        _all = list;
        _loading = false;
        if (_selectedSection != 'All' &&
            !list.any((w) => w.section == _selectedSection)) {
          _selectedSection = 'All';
          _selectedWeek = 'All';
        }
        if (_selectedWeek != 'All' &&
            !list.any((w) =>
                w.weekLabel == _selectedWeek &&
                (_selectedSection == 'All' || w.section == _selectedSection))) {
          _selectedWeek = 'All';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_all.isEmpty) {
          _error =
              'Could not load wallpapers.\nCheck your internet, then pull down to retry.';
        }
      });
      if (_all.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: ${friendlyError(e)}')),
        );
      }
    }
  }

  Widget _message(String text) {
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.4)),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap,
      {bool isNew = false, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: icon == null ? null : Icon(icon, size: 18),
        showCheckmark: false,
        label: Text(isNew ? '$label  ✨' : label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _browse() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _message(_error!);
    if (_all.isEmpty) {
      return _message('No wallpapers yet 🏴‍☠️\nNew ones are added every week!');
    }

    final sections = <String>{for (final w in _all) w.section}.toList()..sort();
    final latestWeek = _all.map((w) => w.weekNum).fold<int>(0, (a, b) => a > b ? a : b);

    final inSection = _selectedSection == 'All'
        ? _all
        : _all.where((w) => w.section == _selectedSection).toList();

    final weeks = <String>[];
    for (final w in inSection) {
      if (!weeks.contains(w.weekLabel)) weeks.add(w.weekLabel);
    }

    final shown = _selectedWeek == 'All'
        ? inSection
        : inSection.where((w) => w.weekLabel == _selectedWeek).toList();

    bool sectionHasNew(String s) =>
        latestWeek > 0 &&
        _all.any((w) => w.section == s && w.weekNum == latestWeek);

    return Column(
      children: [
        if (sections.length > 1)
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: [
                _chip('All sections', _selectedSection == 'All', () {
                  setState(() {
                    _selectedSection = 'All';
                    _selectedWeek = 'All';
                  });
                }, icon: Icons.folder_copy_rounded),
                for (final s in sections)
                  _chip(s, _selectedSection == s, () {
                    setState(() {
                      _selectedSection = s;
                      _selectedWeek = 'All';
                    });
                  }, isNew: sectionHasNew(s), icon: Icons.folder_rounded),
              ],
            ),
          ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              _chip('All weeks', _selectedWeek == 'All',
                  () => setState(() => _selectedWeek = 'All')),
              for (final wk in weeks)
                _chip(wk, _selectedWeek == wk,
                    () => setState(() => _selectedWeek = wk),
                    isNew: latestWeek > 0 && wk == 'Week $latestWeek'),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(force: true),
            child: WallGrid(items: shown, latestWeek: latestWeek),
          ),
        ),
      ],
    );
  }

  Widget _favorites() {
    return ListenableBuilder(
      listenable: favStore,
      builder: (context, _) {
        final items = _all.where((w) => favStore.has(w.path)).toList();
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No favorites yet.\nOpen a wallpaper and tap the heart ❤️',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, height: 1.4),
              ),
            ),
          );
        }
        return WallGrid(items: items, latestWeek: 0);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(kAppName),
        centerTitle: true,
        backgroundColor: Colors.transparent,
      ),
      body: _tab == 0 ? _browse() : _favorites(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.grid_view_rounded), label: 'Browse'),
          NavigationDestination(
              icon: Icon(Icons.favorite_rounded), label: 'Favorites'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- grid

class WallGrid extends StatelessWidget {
  final List<Wallpaper> items;
  final int latestWeek;

  const WallGrid({super.key, required this.items, required this.latestWeek});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.58,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final w = items[i];
        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ViewerPage(items: items, index: i),
              ),
            );
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: w.url,
                  fit: BoxFit.cover,
                  memCacheWidth: 500,
                  placeholder: (_, __) =>
                      Container(color: const Color(0xFF1A1A22)),
                  errorWidget: (_, __, ___) => Container(
                    color: const Color(0xFF1A1A22),
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
                if (latestWeek > 0 && w.weekNum == latestWeek)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('NEW',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: ListenableBuilder(
                    listenable: favStore,
                    builder: (_, __) => favStore.has(w.path)
                        ? const Icon(Icons.favorite,
                            color: Colors.redAccent, size: 22)
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- viewer

class ViewerPage extends StatefulWidget {
  final List<Wallpaper> items;
  final int index;

  const ViewerPage({super.key, required this.items, required this.index});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _pc = PageController(initialPage: widget.index);
  late int _cur = widget.index;
  bool _busy = false;

  Wallpaper get _w => widget.items[_cur];

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _save() async {
    if (_busy) return;
    final w = _w;
    setState(() => _busy = true);
    try {
      final f = await fetchToTemp(w);
      var ok = await Gal.hasAccess();
      if (!ok) ok = await Gal.requestAccess();
      if (!ok) {
        _toast('Storage permission was denied');
      } else {
        await Gal.putImage(f.path, album: kAlbum);
        _toast('Saved to gallery ✅');
      }
    } catch (e) {
      _toast('Something went wrong: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openPreview() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PreviewPage(wallpaper: _w)),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap,
      {Color? color}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: onTap,
          iconSize: 28,
          icon: Icon(icon, color: color),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _w.section == 'General'
        ? _w.weekLabel
        : '${_w.section} • ${_w.weekLabel}';
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('$title  (${_cur + 1}/${widget.items.length})',
            style: const TextStyle(fontSize: 15)),
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pc,
            itemCount: widget.items.length,
            onPageChanged: (i) => setState(() => _cur = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: widget.items[i].url,
                  fit: BoxFit.contain,
                  placeholder: (_, __) =>
                      const Center(child: CircularProgressIndicator()),
                  errorWidget: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined, size: 48)),
                ),
              ),
            ),
          ),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ListenableBuilder(
                      listenable: favStore,
                      builder: (_, __) {
                        final f = favStore.has(_w.path);
                        return _btn(
                          f ? Icons.favorite : Icons.favorite_border,
                          f ? 'Saved' : 'Favorite',
                          () => favStore.toggle(_w.path),
                          color: f ? Colors.redAccent : null,
                        );
                      },
                    ),
                    _btn(Icons.download_rounded, 'Download',
                        _busy ? null : _save),
                    _btn(Icons.wallpaper_rounded, 'Set',
                        _busy ? null : _openPreview),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- preview

class PreviewPage extends StatefulWidget {
  final Wallpaper wallpaper;

  const PreviewPage({super.key, required this.wallpaper});

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  String _target = 'both';
  bool _overlay = true;
  bool _busy = false;

  Future<void> _apply() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final f = await fetchToTemp(widget.wallpaper);
      await kChannel
          .invokeMethod('setWallpaper', {'path': f.path, 'target': _target});
      messenger.showSnackBar(
        const SnackBar(content: Text('Wallpaper set 🎉')),
      );
      if (mounted) nav.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not set wallpaper: ${friendlyError(e)}')),
      );
      if (mounted) setState(() => _busy = false);
    }
  }

  static const List<Shadow> _shadow = [
    Shadow(blurRadius: 10, color: Colors.black54),
  ];

  Widget _lockMock() {
    final now = DateTime.now();
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final m = now.minute.toString().padLeft(2, '0');
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 80),
          Text(
            '${days[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}',
            style: const TextStyle(fontSize: 18, shadows: _shadow),
          ),
          Text(
            '$h:$m',
            style: const TextStyle(
                fontSize: 84, fontWeight: FontWeight.w300, shadows: _shadow),
          ),
          const Spacer(),
          const Icon(Icons.lock_rounded, color: Colors.white70),
          const SizedBox(height: 190),
        ],
      ),
    );
  }

  Widget _homeMock() {
    Widget icon() => Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(14),
          ),
        );
    Widget row() => Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [icon(), icon(), icon(), icon()],
        );
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 90),
          row(),
          const SizedBox(height: 28),
          row(),
          const SizedBox(height: 28),
          row(),
          const Spacer(),
          row(),
          const SizedBox(height: 190),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Preview', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Show or hide phone mock-up',
            icon: Icon(_overlay ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _overlay = !_overlay),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: CachedNetworkImage(
              imageUrl: widget.wallpaper.url,
              fit: BoxFit.cover,
              placeholder: (_, __) =>
                  const Center(child: CircularProgressIndicator()),
              errorWidget: (_, __, ___) => const Center(
                  child: Icon(Icons.broken_image_outlined, size: 48)),
            ),
          ),
          if (_overlay)
            Positioned.fill(
              child: IgnorePointer(
                child: _target == 'home' ? _homeMock() : _lockMock(),
              ),
            ),
          if (_busy)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SegmentedButton<String>(
                        segments: const <ButtonSegment<String>>[
                          ButtonSegment<String>(
                              value: 'home', label: Text('Home')),
                          ButtonSegment<String>(
                              value: 'lock', label: Text('Lock')),
                          ButtonSegment<String>(
                              value: 'both', label: Text('Both')),
                        ],
                        selected: {_target},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) =>
                            setState(() => _target = s.first),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed:
                                  _busy ? null : () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: _busy ? null : _apply,
                              child: const Text('Set wallpaper'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
