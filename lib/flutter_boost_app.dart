import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_boost/messages.dart';
import 'package:flutter_boost/boost_flutter_router_api.dart';
import 'package:flutter_boost/logger.dart';
import 'package:flutter_boost/boost_navigator.dart';
import 'package:flutter_boost/page_visibility.dart';
import 'package:flutter_boost/overlay_entry.dart';

import 'package:uuid/uuid.dart';

import 'page_visibility.dart';
import 'dart:async';

final navigatorKey = GlobalKey<NavigatorState>();

typedef FlutterBoostAppBuilder = Widget Function(Widget home);

typedef FlutterBoostRouteFactory = Route<dynamic> Function(
    RouteSettings settings, String uniqueId);

///
/// 生成UniqueId
///
String createUniqueId(String pageName) {
  if (kReleaseMode) {
    return Uuid().v4();
  } else {
    return Uuid().v4() + '#$pageName';
  }
}

///
///
///
///
class FlutterBoostApp extends StatefulWidget {
  const FlutterBoostApp(this.routeFactory,
      {FlutterBoostAppBuilder appBuilder, String initialRoute, this.observers})
      : appBuilder = appBuilder ?? _materialAppBuilder,
        initialRoute = initialRoute ?? '/';

  final FlutterBoostRouteFactory routeFactory;
  final FlutterBoostAppBuilder appBuilder;
  final List<NavigatorObserver> observers;
  final String initialRoute;

  static Widget _materialAppBuilder(Widget home) {
    return MaterialApp(home: home);
  }

  @override
  State<StatefulWidget> createState() => FlutterBoostAppState();
}

class FlutterBoostAppState extends State<FlutterBoostApp> {
  final Map<String, Completer<Object>> _pendingResult = {};
  List<BoostContainer<dynamic>> get containers => _containers;
  final List<BoostContainer<dynamic>> _containers = [];

  BoostContainer get topContainer => containers.last;

  NativeRouterApi get nativeRouterApi => _nativeRouterApi;
  NativeRouterApi _nativeRouterApi;

  BoostFlutterRouterApi get boostFlutterRouterApi => _boostFlutterRouterApi;
  BoostFlutterRouterApi _boostFlutterRouterApi;

  FlutterBoostRouteFactory get routeFactory => widget.routeFactory;

  @override
  void initState() {
    _containers.add(_createContainer(PageInfo(pageName: widget.initialRoute)));
    _nativeRouterApi = NativeRouterApi();
    _boostFlutterRouterApi = BoostFlutterRouterApi.instance(this);
    super.initState();
  }

  ///     1. onWillPop 先从父层收到事件，再到子层.
  ///     当子层返回 false 时候。父的maybePop 才会true.
  ///     当子层返回 true 时候。父的maybePop 才会false.
  ///
  @override
  Widget build(BuildContext context) {

      return widget.appBuilder(WillPopScope(
          onWillPop: () async {
            bool canPop = topContainer.navigator.canPop();
            if (canPop) {
              topContainer.navigator.pop();
              return true;
            }
            return false;
          },
          child: Overlay(
            key: overlayKey,
            initialEntries: const <OverlayEntry>[],
          )));

  }

  bool _onPopPage(Route<dynamic> route, dynamic result) {
    return false;
  }

  void refresh(){
    refreshOverlayEntries(containers);
  }
  ///
  /// 创建页面
  BoostContainer _createContainer(PageInfo pageInfo) {
    pageInfo.uniqueId ??= createUniqueId(pageInfo.pageName);
    return BoostContainer<dynamic>(
        key: ValueKey(pageInfo.uniqueId),
        pageInfo: pageInfo,
        routeFactory: widget.routeFactory,
        observers: widget.observers);
  }

  Future<T> pushWithResult<T extends Object>(String pageName,
      {String uniqueId, Map arguments, bool withContainer}) {
    final Completer completer = Completer<T>();
    uniqueId ??= createUniqueId(pageName);
    if (withContainer) {
      CommonParams params = CommonParams()
        ..pageName = pageName
        ..uniqueId = uniqueId
        ..arguments = arguments;
      nativeRouterApi.pushFlutterRoute(params);
    } else {
      push(pageName,
          uniqueId: uniqueId, arguments: arguments, withContainer: false);
    }
    _pendingResult[uniqueId] = completer;
    return completer.future;
  }

  void push(String pageName,
      {String uniqueId, Map arguments, bool withContainer}) {
    final BoostContainer existed = _findContainerByUniqueId(uniqueId);
    if (existed != null) {
      if (topContainer?.pageInfo?.uniqueId != uniqueId) {
        containers.remove(existed);
        containers.add(existed);
        refresh();
        PageVisibilityBinding.instance.dispatchPageShowEvent(
            _getCurrentPage(), ChangeReason.routeReorder);
        if (containers.length > 1) {
          String prevPage = containers[containers.length - 2]
              ?.pages
              ?.last
              ?.pageInfo
              ?.uniqueId;
          PageVisibilityBinding.instance
              .dispatchPageHideEvent(prevPage, ChangeReason.routeReorder);
        }
      }
    } else {
      PageInfo pageInfo = PageInfo(
          pageName: pageName,
          uniqueId: uniqueId ?? createUniqueId(pageName),
          arguments: arguments,
          withContainer: withContainer);
      if (withContainer) {
        // setState(() {
          containers.add(_createContainer(pageInfo));
        // });
          refresh();
        PageVisibilityBinding.instance
            .dispatchPageShowEvent(_getCurrentPage(), ChangeReason.routePushed);
        if (containers.length > 1) {
          String prevPage = containers[containers.length - 2]
              ?.pages
              ?.last
              ?.pageInfo
              ?.uniqueId;
          PageVisibilityBinding.instance
              .dispatchPageHideEvent(prevPage, ChangeReason.routePushed);
        }
      } else {
        setState(() {
          topContainer.pages
              .add(BoostPage.create(pageInfo, topContainer.routeFactory));
        });
      }
    }
    Logger.log(
        'push page, uniqueId=$uniqueId, existed=$existed, withContainer=$withContainer, arguments:$arguments, $containers');
  }

  ///
  /// 关闭操作
  ///
  void popWithResult<T extends Object>([T result]) {
    String uniqueId = topContainer?.topPage.pageInfo.uniqueId;
    if (_pendingResult.containsKey(uniqueId)) {
      _pendingResult[uniqueId].complete(result);
    }
    pop();
  }

  void pop({String uniqueId, Map arguments}) async {
    BoostContainer container;
    if (uniqueId != null) {
      container = _findContainerByUniqueId(uniqueId);
      if (container == null) {
        Logger.error('uniqueId=$uniqueId not find');
        return;
      }
      if (container != topContainer) {
        _removeContainer(container);
        return;
      }
    } else {
      container = topContainer;
    }

    final bool handled = await container?.navigator?.maybePop();
    if (handled != null && !handled) {
      if (_getCurrentPage() == container?.pageInfo?.uniqueId) {
        PageVisibilityBinding.instance
            .dispatchPageHideEvent(_getCurrentPage(), ChangeReason.routePopped);
        if (containers.length > 1) {
          String prevPage = containers[containers.length - 2]
              ?.pages
              ?.last
              ?.pageInfo
              ?.uniqueId;
          PageVisibilityBinding.instance
              .dispatchPageShowEvent(prevPage, ChangeReason.routePushed);
        }
      }
      assert(container.pageInfo.withContainer);
      CommonParams params = CommonParams()
        ..pageName = container.pageInfo.pageName
        ..uniqueId = container.pageInfo.uniqueId
        ..arguments = arguments;
      _nativeRouterApi.popRoute(params);
    }
    _pendingResult.remove(uniqueId);

    Logger.log(
        'pop container, uniqueId=$uniqueId, arguments:$arguments, $container');
  }

  void _removeContainer(BoostContainer page) {
    containers.remove(page);
    if (page.pageInfo.withContainer) {
      Logger.log('_removeContainer ,  uniqueId=${page.pageInfo.uniqueId}');
      CommonParams params = CommonParams()
        ..pageName = page.pageInfo.pageName
        ..uniqueId = page.pageInfo.uniqueId
        ..arguments = page.pageInfo.arguments;
      _nativeRouterApi.popRoute(params);
    }
  }

  void onForeground() {
    PageVisibilityBinding.instance.dispatchForegroundEvent(_getCurrentPage());
  }

  void onBackground() {
    PageVisibilityBinding.instance.dispatchBackgroundEvent(_getCurrentPage());
  }

  void onNativeViewShow() {
    PageVisibilityBinding.instance
        .dispatchPageHideEvent(_getCurrentPage(), ChangeReason.viewPushed);
  }

  void onNativeViewHide() {
    PageVisibilityBinding.instance
        .dispatchPageShowEvent(_getCurrentPage(), ChangeReason.viewPopped);
  }

  String _getCurrentPage() {
    return topContainer?.topPage?.pageInfo?.uniqueId;
  }

  bool _isCurrentPage(String uniqueId) {
    return topContainer?.pageInfo?.uniqueId == uniqueId;
  }

  BoostContainer _findContainerByUniqueId(String uniqueId) {
    return containers.singleWhere(
        (BoostContainer element) => element.pageInfo?.uniqueId == uniqueId,
        orElse: () => null);
  }

  void remove(String uniqueId) {
    if (uniqueId == null) return;
    final BoostContainer container = _findContainerByUniqueId(uniqueId);
    if (container != null) {
      containers.removeWhere((entry) => entry.pageInfo?.uniqueId == uniqueId);
      refresh();
    } else {
      containers.forEach((container) {
        container.pages
            .removeWhere((entry) => entry.pageInfo?.uniqueId == uniqueId);
      });
      refresh();
    }
    Logger.log('remove,  uniqueId=$uniqueId, $containers');
  }

  PageInfo getTopPageInfo() {
    return topContainer?.topPage?.pageInfo;
  }

  int pageSize() {
    int count = 0;
    containers.forEach((container) {
      count += container.size;
    });
    return count;
  }
}

///
/// boost定义的page
///
class BoostPage<T> extends Page<T> {
  BoostPage({LocalKey key, this.routeFactory, this.pageInfo})
      : super(key: key, name: pageInfo.pageName, arguments: pageInfo.arguments);

  final FlutterBoostRouteFactory routeFactory;
  final PageInfo pageInfo;

  static BoostPage create(
      PageInfo pageInfo, FlutterBoostRouteFactory routeFactory) {
    return BoostPage<dynamic>(
        key: UniqueKey(), pageInfo: pageInfo, routeFactory: routeFactory);
  }

  @override
  String toString() =>
      '${objectRuntimeType(this, 'BoostPage')}(name:$name, uniqueId:${pageInfo.uniqueId}, arguments:$arguments)';

  @override
  Route<T> createRoute(BuildContext context) {
    return routeFactory(this, pageInfo.uniqueId);
  }
}

class _BoostNavigatorObserver extends NavigatorObserver {
  final List<NavigatorObserver> observers;
  _BoostNavigatorObserver(this.observers);

  @override
  void didPush(Route<dynamic> route, Route<dynamic> previousRoute) {
    observers?.forEach((element) {
      element.didPush(route, previousRoute);
    });

    //handle internal route
    if (previousRoute != null) {
      PageVisibilityBinding.instance
          .dispatchPageShowEventForRoute(route, ChangeReason.routePushed);
      PageVisibilityBinding.instance.dispatchPageHideEventForRoute(
          previousRoute, ChangeReason.routePushed);
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic> previousRoute) {
    observers?.forEach((element) {
      element.didPop(route, previousRoute);
    });

    if (previousRoute != null) {
      PageVisibilityBinding.instance
          .dispatchPageHideEventForRoute(route, ChangeReason.routePopped);
      PageVisibilityBinding.instance.dispatchPageShowEventForRoute(
          previousRoute, ChangeReason.routePopped);
    }
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic> previousRoute) {
    observers?.forEach((element) {
      element.didRemove(route, previousRoute);
    });
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic> newRoute, Route<dynamic> oldRoute}) {
    observers?.forEach((element) {
      element.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    });
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  @override
  void didStartUserGesture(Route<dynamic> route, Route<dynamic> previousRoute) {
    observers?.forEach((element) {
      element.didStartUserGesture(route, previousRoute);
    });
    super.didStartUserGesture(route, previousRoute);
  }

  @override
  void didStopUserGesture() {
    observers?.forEach((element) {
      element.didStopUserGesture();
    });
    super.didStopUserGesture();
  }
}

class BoostContainer<T> extends StatelessWidget {
  BoostContainer(
      {LocalKey key,
      this.observers, this.routeFactory, this.pageInfo}) {
    pages.add(BoostPage.create(pageInfo, routeFactory));
  }
  final FlutterBoostRouteFactory routeFactory;
  final PageInfo pageInfo;

  final List<BoostPage<dynamic>> _pages = <BoostPage<dynamic>>[];
  final List<NavigatorObserver> observers;

  List<BoostPage<dynamic>> get pages => _pages;
  BoostPage get topPage => pages.last;
  int get size => pages.length;

  NavigatorState get navigator => _navKey.currentState;
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  void _updatePagesList() {
    pages.removeLast();
  }

  Widget build(BuildContext context) {
    return Navigator(
      key: _navKey,
      pages: List.of(_pages),
     onPopPage: (route, dynamic result) {
        if (route.didPop(result)) {
          _updatePagesList();
          return true;
        }
        return false;
      },
      observers: [
        _BoostNavigatorObserver(observers),
      ],
    );
  }

}

