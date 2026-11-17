import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/index.dart';
import 'package:pure_live/domains/live/presentation/playback/controllers/live_play_controller.dart';

void main() {
  test('镜像聊天按原对象同时写入历史、画面和小窗层，不改用户名和正文', () {
    final message = LiveMessage(
      type: LiveMessageType.chat,
      userName: 'B 用户',
      userId: 'b-user',
      message: 'B 的原始弹幕',
      messageId: 'b-message',
      color: LiveMessageColor.white,
    );
    final history = <LiveMessage>[];
    final video = <LiveMessage>[];
    final floating = <LiveMessage>[];

    deliverMirrorChatToRoom(message, addToHistory: history.add, addToVideo: video.add, addToFloating: floating.add);

    expect(history.single, same(message));
    expect(video.single, same(message));
    expect(floating.single, same(message));
    expect(message.userName, 'B 用户');
    expect(message.message, 'B 的原始弹幕');
    expect(message.userId, 'b-user');
    expect(message.messageId, 'b-message');
  });

  test('画面层不可用时仍然写入历史和小窗层', () {
    final message = LiveMessage(
      type: LiveMessageType.chat,
      userName: 'B 用户',
      message: 'B 的原始弹幕',
      color: LiveMessageColor.white,
    );
    final history = <LiveMessage>[];
    final floating = <LiveMessage>[];

    deliverMirrorChatToRoom(message, addToHistory: history.add, addToVideo: null, addToFloating: floating.add);

    expect(history.single, same(message));
    expect(floating.single, same(message));
  });

  test('路由关闭但保留小窗时，镜像系统消息仍写入小窗层', () {
    final history = <LiveMessage>[];
    final floating = <LiveMessage>[];

    deliverMirrorSystemMessage(
      'B 连接失败',
      isClosed: true,
      keepsFloating: true,
      addToHistory: history.add,
      addToFloating: floating.add,
    );

    expect(history, isEmpty);
    expect(floating.single.message, 'B 连接失败');
    expect(floating.single.userName, i18n('system_message'));
  });

  test('路由关闭且没有小窗时，镜像系统消息不写入已关闭的历史', () {
    final history = <LiveMessage>[];
    final floating = <LiveMessage>[];

    deliverMirrorSystemMessage(
      'B 连接失败',
      isClosed: true,
      keepsFloating: false,
      addToHistory: history.add,
      addToFloating: floating.add,
    );

    expect(history, isEmpty);
    expect(floating, isEmpty);
  });

  test('路由未关闭时，镜像系统消息只写入历史', () {
    final history = <LiveMessage>[];
    final floating = <LiveMessage>[];

    deliverMirrorSystemMessage(
      '已同步 B',
      isClosed: false,
      keepsFloating: false,
      addToHistory: history.add,
      addToFloating: floating.add,
    );

    expect(history.single.message, '已同步 B');
    expect(floating, isEmpty);
  });
}
