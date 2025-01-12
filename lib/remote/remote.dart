import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:oktoast/oktoast.dart';
import 'package:watch_together/dlna/dlna_flutter.dart';
import 'package:watch_together/remote/model.dart';

import 'action.dart';

typedef VoidCallback = void Function(bool);

/// 同步服务端地址
// const host = "47.99.190.206"; //big
const host = "112.74.55.142"; //阿里云
// const host = "192.168.2.1";
const int remotePort = 51127; //服务器端口

///跟服务端交互，获取 播放状态
class Remote {
  ///播放器控制回调
  PlayerAction? _callback;

  ///服务器返回信息回调
  VoidCallback? _remoteCallback;

  ///远程状态
  PlayStateModel _remoteState = PlayStateModel(action: "");

  ///远端地址
  InternetAddress remoteAddress = InternetAddress(host);

  static Socket? _socket;

  ///获取房间id
  get roomId => _remoteState.roomId;

  ///是否是房主
  get isRoomOwner => _remoteState.isOwner;

  //心跳计时器
  Timer? _heartBeatTimer;

  //本地客服端和服务器时间差
  int _serverTimeDiff = 0;

  ///构造函数异步初始化udp
  Remote() {
    Future.microtask(() {
      _start();
    });
  }

  ///开启服务
  void _start() async {
    Socket.connect(host, remotePort, timeout: const Duration(seconds: 10))
        .then((socket) {
      _socket = socket;
      _listen();
    }).catchError(_onError);
  }

  ///设置播放回调
  void setActionCallback(PlayerAction callback) {
    _callback = callback;
  }

  ///设置服务器返回信息回调
  void setRemoteCallback(VoidCallback onRemoteCallback) {
    _remoteCallback = onRemoteCallback;
  }

  /// 接收对面数据
  void _listen() async {
    _socket?.listen(_onData, onDone: _onDone, onError: _onError);
    showToast("连接服务器成功");
    if (roomId.isNotEmpty) {
      join(roomId);
    }
  }

  ///接收到服务器数据
  void _onData(data) {
    var text = String.fromCharCodes(data);
    //处理tcp沾包问题
    text.split('\n').forEach((element) {
      if (element.startsWith('{') && element.endsWith('}')) {
        _parse(element);
      }
    });
  }

  ///服务器连接断开
  void _onDone() {
    if (kDebugMode) {
      print("onDone");
    }
    _socket?.close();
    _socket = null;
    _heartBeatTimer?.cancel();
    _heartBeatTimer = null;
    //自动重连
    showToast("连接已断开,2秒后自动重连");
    Future.delayed(const Duration(seconds: 2), () {
      _start();
    });
  }

  ///连接出错
  void _onError(err) {
    if (kDebugMode) {
      print(err);
    }
    _socket = null;
    _heartBeatTimer?.cancel();
    _heartBeatTimer = null;
    _remoteCallback?.call(false);
    showToast("连接出错");
  }

  ///发送当前状态
  void _send(PlayStateModel model) {
    model.timestamp = _getServerTime();
    var json = JsonParse.modelToJson(model);
    if (kDebugMode) {
      print("send : $json");
    }
    if (_socket == null) {
      _remoteCallback?.call(false);
      showToast("连接服务器失败,请过会儿重启app后再尝试");
    } else {
      _socket?.writeln(json);
    }
  }

  /// json 转对象
  void _parse(String text) {
    if (kDebugMode) {
      print("remote receive : $text");
    }
    PlayStateModel model = JsonParse.jsonToModel(text);
    _executeTimeDiff(model);
    _doAction(model);
  }

  ///计算服务器和本地时间差
  void _executeTimeDiff(PlayStateModel model) {
    var serverTime = model.timestamp;
    var current = DateTime.now().millisecondsSinceEpoch;
    _serverTimeDiff = serverTime - current;
  }

  ///获取消除误差后的时间
  int _getServerTime() {
    var current = DateTime.now().millisecondsSinceEpoch;
    return current + _serverTimeDiff;
  }

  ///执行对方的动作
  void _doAction(PlayStateModel model) {
    _remoteState = model;
    Action action = model.actionEnum();
    switch (action) {
      case Action.idle:
        //创建房间成功
        _onCreateRoom();
        break;
      case Action.join:
        //加入房间成功
        _onJoinRoom();
        break;
      case Action.sync:
        //同步播放状态
        _onSync();
        break;
      case Action.url:
        // 设置播放地址
        _remoteState.url = model.url;
        _callback?.setUrl(model.url);
        break;
      case Action.play:
        // 播放视频
        _remoteState.isPlaying = true;
        _callback?.play();
        break;
      case Action.pause:
        // 暂停视频
        _remoteState.isPlaying = false;
        _callback?.pause();
        break;
      case Action.seek:
        // 进度跳转
        _onSync();
        break;
      case Action.exit:
        // 房间已解散
        showToast("房间已解散");
        _heartBeatTimer?.cancel();
        break;
      case Action.heartbeat:
        break;
    }
  }

  ///创建房间成功
  void _onCreateRoom() async {
    if (kDebugMode) {
      print("心跳开启");
    }
    _remoteCallback?.call(true);
    _remoteCallback = null;

    ///开启心跳同步播放状态
    _heartBeatTimer?.cancel();
    _heartBeatTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      _heartbeat();
    });
  }

  ///加入房间成功
  void _onJoinRoom() {
    _remoteCallback?.call(true);
    _remoteCallback = null;
    //开启心跳保持连接活动
    _heartBeatTimer?.cancel();
    _heartBeatTimer =
        Timer.periodic(Duration(seconds: isRoomOwner ? 3 : 5), (timer) {
      _heartbeat();
    });
  }

  ///请求同步信息成功
  void _onSync() {
    var url = _remoteState.url;
    if (url.isEmpty) {
      return;
    }
    _callback?.setUrl(url);
    var position = _remoteState.position + 1;
    _callback?.seek(position);
    if (_remoteState.isPlaying) {
      _callback?.play();
    } else {
      _callback?.pause();
    }
  }

  /// 加入房间或者创建房间
  void join(String roomId) {
    if (roomId.isEmpty) return;
    var model = _remoteState;
    model.action = "join";
    model.roomId = roomId;
    _send(model);
  }

  ///退出房间
  void exit() {
    if (roomId.isEmpty) return;
    _heartBeatTimer?.cancel();
    var model = _remoteState.copyWith(action: "exit");
    model.roomId = roomId;
    _send(model);
  }

  /// 接收到投屏的视频地址，发送给远端
  void setUrl(String url) {
    if (!isRoomOwner) return;
    var model = _remoteState;
    model.action = "url";
    _remoteState.url = url;
    _send(model);
  }

  ///播放视频
  void play() {
    if (!isRoomOwner) return;
    var model = _remoteState;
    model.action = "play";
    model.isPlaying = true;
    _send(model);
  }

  ///暂停视频
  void pause() {
    if (!isRoomOwner) return;
    var model = _remoteState;
    model.action = "pause";
    model.isPlaying = false;
    _send(model);
  }

  ///同步进度
  void seek(int position) {
    if (!isRoomOwner) return;
    var model = _remoteState;
    model.action = "seek";
    model.position = position;
    _send(model);
  }

  ///和远程同步进度
  void syncRemote() {
    var model = _remoteState;
    if (model.isOwner) return;
    model.action = "sync";
    _send(model);
  }

  ///心跳
  void _heartbeat() async {
    var model = _remoteState.copyWith(url: ""); //心跳省略url，减少带宽消耗
    model.action = "heartbeat";
    model.position = _callback?.getPosition() ?? 0;
    _send(model);
  }

  ///关闭端口，释放资源
  void dispose() {
    _socket?.close();
    _socket = null;
  }
}
