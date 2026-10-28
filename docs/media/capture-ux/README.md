# 取景体验录屏证据（2026-10-27）

本目录只放缩小后的联系表和关键成片，原始录屏在
`docs/media/screenrecord/`（六段，本地验收素材，暂不纳入 Git；其中视频 5 约 421MB）：

- `1-ScreenRecording_10-27-2026-18-54-26_1.MP4`：粉色封面
- `2-ScreenRecording_10-27-2026-18-47-22_1.MP4`：右页，白线锁定后拍成功
- `3-ScreenRecording_10-27-2026-18-47-48_1.MP4`：右页，取景框跳跃时成片带左页/背景
- `4-ScreenRecording_10-27-2026-18-51-59_1.MP4`：左页，框无法定位左页，成片为整摊
- `5-ScreenRecording_10-28-2026-08-57-44_1.MP4`：彩色/黑白书的右页、左页、整页
  复核；右/左页目标框频繁不出现，整页框更容易出现但会带入背景（本地，421MB）
- `6-758bab6ec69ae4b25d8fbef77ff8c8e0.mp4`：WPS 万能扫描对照；蓝色框连续跟随
  整摊/书外轮廓，拍后输出单页（本地，8.9MB）

视频 5/6 的联系表与关键帧：

- `video5-color-timeline.jpg` / `video5-bw-timeline-*.jpg` / `video5-final-timeline.jpg`
- `video5-right-no-frame.jpg` / `video5-whole-frame.jpg`
- `video6-wps-timeline.jpg` / `video6-wps-spread-frame.jpg` / `video6-wps-result.jpg`

关键成片：

- `pink-cover-result.jpg`：修复前设备成片，顶部粉带被洗白；
- `pink-cover-fixed.jpg`：修复后用设备原图 + DB quad 本地重渲染，顶部粉带保留；
- `right-page-good.jpg` / `left-page-intent-failure.jpg`：右页对照 / 左页误拍整摊。

P0.2 根因：`docs/21-capture-ux-stability.md`；P0.3 包络跟踪方案：`docs/22-capture-envelope-tracking.md`。
