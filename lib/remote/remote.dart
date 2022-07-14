import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:oktoast/oktoast.dart';
import 'package:watch_together/dlna/dlna_flutter.dart';
import 'package:watch_together/remote/model.dart';

typedef VoidCallback = void Function();

/// 同步服务端地址
// const host = "192.168.2.1";
// const host = "47.99.190.206"; //big
const host = "112.74.55.142"; //我的阿里云
const int remotePort = 51127; //服务器端口

///跟服务端交互，获取 播放状态
class Remote {
  ///播放器控制回调
  PlayerAction? _callback;

  ///服务器返回信息回调
  VoidCallback? _remoteCallback;

  ///远程状态
  PlayStateModel _remoteState = PlayStateModel();

  ///远端地址
  InternetAddress remoteAddress = InternetAddress(host);

  static late Socket _socket;

  get roomId => _remoteState.roomId;

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
    _socket.listen(_onData, onDone: _onDone, onError: _onError);
    showToast("连接服务器成功");
  }

  ///接收到服务器数据
  void _onData(data) {
    var text = String.fromCharCodes(data);
    _parse(text);
  }

  ///服务器连接断开
  void _onDone() {
    if (kDebugMode) {
      print("onDone");
    }
    showToast("连接已断开");
  }

  ///连接出错
  void _onError(err) {
    if (kDebugMode) {
      print(err);
    }
    showToast("连接出错");
  }

  ///发送当前状态
  void _send(PlayStateModel model) {
    var json = JsonParse.modelToJson(model);
    if (kDebugMode) {
      print("send : $json");
    }
    _socket.write(json);
  }

  /// json 转对象
  void _parse(String text) {
    if (kDebugMode) {
      print("remote receive : $text");
    }
    PlayStateModel model = JsonParse.jsonToModel(text);
    _doAction(model);
  }

  ///执行对方的动作
  void _doAction(PlayStateModel model) {
    _remoteState = model;
    var action = model.action;
    switch (action) {
      case 'idle':
        //创建房间成功
        _onCreateRoom();
        break;
      case 'join':
        //加入房间成功
        _onJoinRoom();
        break;
      case 'sync':
        //同步播放状态
        _onSync();
        break;
      case 'url':
        // 设置播放地址
        _remoteState.url = model.url;
        _callback?.setUrl(model.url);
        break;
      case 'play':
        // 播放视频
        _remoteState.isPlaying = true;
        _callback?.play();
        break;
      case 'pause':
        // 暂停视频
        _remoteState.isPlaying = false;
        _callback?.pause();
        break;
      case 'seek':
        // 进度跳转
        _onSync();
        break;
    }
  }

  ///创建房间成功
  void _onCreateRoom() async {
    if (kDebugMode) {
      print("心跳开启");
    }

    ///开启心跳同步播放状态
    Timer.periodic(const Duration(seconds: 3), (timer) {
      _heartbeat();
    });
    _remoteCallback?.call();
  }

  ///加入房间成功
  void _onJoinRoom() {
    _remoteCallback?.call();

    ///开启心跳保持连接活动
    Timer.periodic(const Duration(seconds: 5), (timer) {
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
    var diff = DateTime.now().millisecondsSinceEpoch - _remoteState.timestamp;
    int diffSecond = diff ~/ 1000;
    //修正误差
    if (diffSecond < 0) {
      diffSecond = 0;
    }
    if (diffSecond > 10) {
      diffSecond = 1;
    }
    var position = _remoteState.position + diffSecond;
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
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _send(model);
  }

  /// 接收到投屏的视频地址，发送给远端
  void setUrl(String url) {
    if (!_remoteState.isOwner) return;
    var model = _remoteState;
    model.action = "url";
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _remoteState.url = url;
    _send(model);
  }

  ///播放视频
  void play() {
    var model = _remoteState;
    model.action = "play";
    model.isPlaying = true;
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _send(model);
  }

  ///暂停视频
  void pause() {
    var model = _remoteState;
    model.action = "pause";
    model.isPlaying = false;
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _send(model);
  }

  ///同步进度
  void seek(int position) {
    var model = _remoteState;
    model.action = "seek";
    model.position = position;
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _send(model);
  }

  ///和远程同步进度
  void syncRemote() {
    var model = _remoteState;
    if (model.isOwner) return;
    model.action = "sync";
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _send(model);
  }

  ///心跳
  void _heartbeat() async {
    var model = _remoteState;
    model.action = "heartbeat";
    model.position = _callback?.getPosition() ?? 0;
    model.timestamp = DateTime.now().millisecondsSinceEpoch;
    _send(model);
  }

  ///关闭端口，释放资源
  void dispose() {
    _socket.close();
  }
}
