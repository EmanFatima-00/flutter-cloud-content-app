// TASK 3 - Cloud-Synced Content Platform with State Management
//
// pubspec.yaml dependencies:
//   dio: ^5.7.0              (Axios-equivalent HTTP client for Dart)
//   provider: ^6.1.2         (state management)
//   shared_preferences: ^2.3.2   (offline cache + saved favorites)
//
// Android: add  <uses-permission android:name="android.permission.INTERNET"/>
// to android/app/src/main/AndroidManifest.xml
//
// Remote API: https://jsonplaceholder.typicode.com/posts (paginated)

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => PostsProvider()..init(),
      child: const ContentApp(),
    ),
  );
}

// ---------------------------------------------------------------------------
// MODEL
// ---------------------------------------------------------------------------
class Post {
  Post({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
  });

  final int id;
  final int userId;
  final String title;
  final String body;

  factory Post.fromJson(Map<String, dynamic> json) => Post(
        id: json['id'] as int,
        userId: json['userId'] as int,
        title: (json['title'] as String? ?? '').trim(),
        body: (json['body'] as String? ?? '').trim(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'title': title,
        'body': body,
      };
}

String capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

// ---------------------------------------------------------------------------
// STATE MANAGEMENT (Provider + ChangeNotifier)
// ---------------------------------------------------------------------------
enum LoadStatus { loading, loaded, error }

class PostsProvider extends ChangeNotifier {
  static const int _limit = 10;
  static const String _cacheKey = 'cached_posts';
  static const String _favKey = 'favorite_post_ids';

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: 'https://jsonplaceholder.typicode.com',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  List<Post> posts = [];
  final Set<int> favorites = {};
  LoadStatus status = LoadStatus.loading;
  String errorMessage = '';
  bool isOffline = false;
  bool hasMore = true;
  bool loadingMore = false;
  String query = '';
  bool favoritesOnly = false;
  int _nextPage = 1;

  List<Post> get visiblePosts {
    final q = query.trim().toLowerCase();
    return posts.where((p) {
      final favOk = !favoritesOnly || favorites.contains(p.id);
      final textOk = q.isEmpty ||
          p.title.toLowerCase().contains(q) ||
          p.body.toLowerCase().contains(q);
      return favOk && textOk;
    }).toList();
  }

  Future<void> init() async {
    await _loadFavorites();
    await fetchPosts();
  }

  // ---- network ------------------------------------------------------------
  Future<void> fetchPosts() async {
    if (posts.isEmpty) {
      status = LoadStatus.loading;
      notifyListeners();
    }
    try {
      final res = await _dio.get(
        '/posts',
        queryParameters: {'_page': 1, '_limit': _limit},
      );
      final list = (res.data as List)
          .map((e) => Post.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      posts = list;
      hasMore = list.length == _limit;
      _nextPage = 2;
      isOffline = false;
      status = LoadStatus.loaded;
      await _saveCache(list);
    } on DioException catch (e) {
      await _fallbackToCache(_describe(e));
    } catch (_) {
      await _fallbackToCache('Something went wrong. Please try again.');
    }
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (loadingMore || !hasMore || isOffline || status != LoadStatus.loaded) {
      return;
    }
    if (query.isNotEmpty || favoritesOnly) return;
    loadingMore = true;
    notifyListeners();
    try {
      final res = await _dio.get(
        '/posts',
        queryParameters: {'_page': _nextPage, '_limit': _limit},
      );
      final list = (res.data as List)
          .map((e) => Post.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      posts = [...posts, ...list];
      hasMore = list.length == _limit;
      _nextPage++;
    } catch (_) {
      // Keep what we already have; user can retry by scrolling again.
      isOffline = true;
    }
    loadingMore = false;
    notifyListeners();
  }

  String _describe(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'The connection timed out.';
      case DioExceptionType.connectionError:
        return 'No internet connection.';
      case DioExceptionType.badResponse:
        return 'Server error (${e.response?.statusCode ?? 'unknown'}).';
      default:
        return 'Network error. Please try again.';
    }
  }

  // ---- offline handling ---------------------------------------------------
  Future<void> _fallbackToCache(String message) async {
    if (posts.isNotEmpty) {
      isOffline = true;
      status = LoadStatus.loaded;
      return;
    }
    final cached = await _loadCache();
    if (cached.isNotEmpty) {
      posts = cached;
      hasMore = false;
      isOffline = true;
      status = LoadStatus.loaded;
    } else {
      errorMessage = message;
      status = LoadStatus.error;
    }
  }

  Future<void> _saveCache(List<Post> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode(list.map((p) => p.toJson()).toList()),
      );
    } catch (_) {}
  }

  Future<List<Post>> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => Post.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---- favorites ----------------------------------------------------------
  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_favKey) ?? [];
      favorites
        ..clear()
        ..addAll(ids.map(int.parse));
    } catch (_) {}
  }

  Future<void> toggleFavorite(int id) async {
    if (!favorites.add(id)) favorites.remove(id);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _favKey,
        favorites.map((e) => e.toString()).toList(),
      );
    } catch (_) {}
  }

  // ---- UI controls --------------------------------------------------------
  void setQuery(String value) {
    query = value;
    notifyListeners();
  }

  void toggleFavoritesOnly() {
    favoritesOnly = !favoritesOnly;
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// APP
// ---------------------------------------------------------------------------
class ContentApp extends StatelessWidget {
  const ContentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloud Content',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      home: const PostsScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// LIST SCREEN
// ---------------------------------------------------------------------------
class PostsScreen extends StatefulWidget {
  const PostsScreen({super.key});

  @override
  State<PostsScreen> createState() => _PostsScreenState();
}

class _PostsScreenState extends State<PostsScreen> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (_controller.hasClients &&
          _controller.position.pixels >=
              _controller.position.maxScrollExtent - 250) {
        context.read<PostsProvider>().loadMore();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PostsProvider>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud Content'),
        actions: [
          IconButton(
            tooltip: state.favoritesOnly ? 'Show all' : 'Show favorites',
            icon: Icon(
              state.favoritesOnly ? Icons.favorite : Icons.favorite_border,
            ),
            onPressed: state.toggleFavoritesOnly,
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.isOffline)
            Container(
              width: double.infinity,
              color: scheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "You're offline. Showing saved content.",
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: state.fetchPosts,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search posts',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: state.setQuery,
            ),
          ),
          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  Widget _buildBody(PostsProvider state) {
    if (state.status == LoadStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.status == LoadStatus.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, size: 64),
              const SizedBox(height: 12),
              Text(
                state.errorMessage,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: state.fetchPosts,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    final items = state.visiblePosts;

    return RefreshIndicator(
      onRefresh: state.fetchPosts,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(child: Text('No posts found.')),
              ],
            )
          : ListView.builder(
              controller: _controller,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              itemCount: items.length + (state.loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= items.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return PostCard(post: items[index]);
              },
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// POST CARD
// ---------------------------------------------------------------------------
class PostImage extends StatelessWidget {
  const PostImage({super.key, required this.postId, this.height = 150});
  final int postId;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      'https://picsum.photos/seed/post$postId/600/300',
      height: height,
      width: double.infinity,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return SizedBox(
          height: height,
          child: const Center(child: CircularProgressIndicator()),
        );
      },
      errorBuilder: (context, error, stack) => Container(
        height: height,
        width: double.infinity,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.image_not_supported_outlined, size: 40),
      ),
    );
  }
}

class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    final isFav =
        context.select<PostsProvider, bool>((p) => p.favorites.contains(post.id));

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PostImage(postId: post.id),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          capitalize(post.title),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          capitalize(post.body),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Favorite',
                    icon: Icon(
                      isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? Colors.red : null,
                    ),
                    onPressed: () =>
                        context.read<PostsProvider>().toggleFavorite(post.id),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DETAIL SCREEN
// ---------------------------------------------------------------------------
class PostDetailScreen extends StatelessWidget {
  const PostDetailScreen({super.key, required this.post});
  final Post post;

  @override
  Widget build(BuildContext context) {
    final isFav =
        context.select<PostsProvider, bool>((p) => p.favorites.contains(post.id));

    return Scaffold(
      appBar: AppBar(
        title: Text('Post #${post.id}'),
        actions: [
          IconButton(
            icon: Icon(
              isFav ? Icons.favorite : Icons.favorite_border,
              color: isFav ? Colors.red : null,
            ),
            onPressed: () =>
                context.read<PostsProvider>().toggleFavorite(post.id),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: PostImage(postId: post.id, height: 220),
              ),
              const SizedBox(height: 16),
              Text(
                capitalize(post.title),
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Author ID: ${post.userId}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 16),
              Text(
                capitalize(post.body),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
