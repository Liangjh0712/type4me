# AI Passport 设备固件

Type4Me 的硬件语音输入设备（FoloToy AI Passport，ESP32-C3）所用的固件，
以及我们对它的改动。

出厂固件（TRAE CARD）把这块板子做成桌面徽章——推图片、昵称、铃声——**没有启用
麦克风**。硬件上麦克风一直都在（ES8311 codec），只是没有代码用它。要拿到语音输入
必须换固件。

## 设备参数

| | |
|---|---|
| 芯片 | ESP32-C3 (QFN32) rev 1.1，单核 160MHz，400KB SRAM，**无 PSRAM** |
| Flash | 8MB (XMC)，factory 分区 4MB |
| 屏幕 | ST7789P3，240×320 竖屏 RGB565 |
| 音频 | ES8311，全双工 I2S，16kHz 单声道 |
| 按键 | UP / DOWN / OK，同一条 ADC 电阻梯（GPIO0） |
| 串口 | 原生 USB Serial/JTAG（GPIO18/19），VID `0x303A` PID `0x1001` |
| 蓝牙 | BLE only（**无经典蓝牙**，所以它无法作为系统麦克风） |

## 上游

固件来自第三方 fork，不是官方出厂固件：

```
https://github.com/zhaohuaxiaoy/folo-ai-passport-voice
基线 commit: 403ea8e244a3
版本:        v0.1.3-10-gb63006b（作者本地构建，非 tag）
ESP-IDF:     v5.5.3
```

它在官方模板 `folotoy/ai-passport` 上实现了按住录音 + 双通道音频上行
（USB 裸 PCM / BLE IMA ADPCM）+ 事件协议。协议细节见
`Type4Me/Device/` 下各文件的注释。

预编译的整片镜像在上游仓库的 `dist/firmware/FoloToy-AI-Passport-full.bin`
（1.27MB，从 `0x0` 刷），本仓库不重复存放。

## 键位

三颗键，同一条 ADC 电阻梯（GPIO0）：UP ≤150mV / DOWN 150–447 / OK 447–1900，
松开态 2890。**同时按多颗只会读出更低的那一档**，所以任何"组合键"都不可能。

| 键 | 待机 | 录音中 | 识别中 |
|---|---|---|---|
| UP（音量+） | 按住说话，松开发送 | 松开 = 发送 | 单击 = 放弃这句 |
| OK | 按住 = 速记（只存历史不注入）；长按 0.5s = 锁屏/解锁 | 松开 = 发送（速记会话） | 单击 = 放弃这句 |
| DOWN（音量−） | 单击 = 回车；长按 0.5s = 清空输入框 | 无（读不出来，见上） | 单击 = 回车 |

同一颗键上只放「单击 + 长按」，不放双击——`main/app_state.c` 文件头有一段
详细的取证：长按到点就宣布，会把双击判死，为此堆过四层补偿仍然别扭。

真假按键靠 PRESS 时刻的 mv 区分（射频腐蚀会造出幽灵事件），CLICK 回调时用户
已松手、mv 恒 2890，判不了——所以状态机记着 `last_up_press_mv` /
`last_ok_press_mv`。

## 我们的改动

`patches/` 下按顺序应用，`files/` 是要拷进固件的新文件：

| 文件 | 内容 |
|---|---|
| `patches/0001-quiet-device-ui.patch` | 重做屏幕：文案改正常大小写、每状态一个吉祥物表情、底部只留当前用得到的那条提示、顶栏加连接方式图标；待机页名牌显示主人名字（读自设备 NVS，见下）。另含：OK 键速记会话、识别期取消会话、全局静音 + codec 空闲释放（见下两节）。 |
| `files/pet_frames.h` | 吉祥物位图的声明（手写，要拷进 `main/`）。 |
| `tools/gen_pet_frames.py` | 从 Codex pet sprite sheet 生成 `main/pet_frames.c`。位图是生成物，不入库——493KB 的 C 数组没必要进 git，改表情改脚本里的 `PICKS` 表重新生成即可。 |

### 取消会话

识别中（松开之后、结果回来之前）单击 UP 或 OK 放弃这句话：设备回待机，
并发 `{"event":"session.abort"}` 上行，Mac 端据此撤销——不注入、不进剪贴板、
不存历史。

**为什么取消只能在松开之后**：三颗键共用一条 ADC 电阻梯，UP 是最低档
（≤150mV）、DOWN 150–447、OK 447+。按住 UP 时同时按任何键，ADC 只读得到更低
的那一档也就是 UP 自己 —— 录音期间的"第二颗键"在硬件上不存在。所以没有
"边说边取消"，只有"说完了不要"。

固件侧原本就有这个退出（只清自己的屏），但不通知 Mac，于是 Mac 照样把放弃掉
的话打进输入框 —— 取消是假的。`session.abort` 这一帧是补的这个洞，属于会话
边界帧（`send_event_line_important`，不丢）。

### 静音与 codec 电源

提示音全部取消（六声：录音就绪 / 发送 / 审批 / 完成 / 拒绝 / 离线）。两处
反馈改成屏幕 toast 而不是一起删掉：DOWN 长按清空显示 `Cleared`（用户凭手感
不知道 500ms 到没到），离线按 UP 显示 `OFFLINE`（原先只设了 toast 却没发
`UI_REFRESH`，等于没有任何反馈，顺手补上）。审批提醒音是六声里唯一"值得响"
的一声——它要把注意力从别处拽回屏幕——但语音输入用不到审批场景，将来接回
Agent 审批时它应该第一个恢复出声。

**顺带修掉一个耗电缺陷**：`esp_codec_dev_open()` 会拉高 5V 功放引脚并保持到
close，而原先唯一的 close 在"换采样率"路径上——全程只用 16kHz，那条路永远
走不到。结果是开机播第一声提示音后功放常开到关机（持续毫安级，远超提示音
本身）。现在 codec 跟着录音走：开流时 open，`APP_CODEC_IDLE_MS`（5 分钟）无
录音后由状态机发 `CODEC_RELEASE` 才真正断电。

不在 stop 时立刻关，是因为重开 codec 有几十毫秒冷启动，会吃掉下一句的第一个
字。留 5 分钟让连续口述保持热态。**实测结论：热态与冷启动的差别用户感知不
明显**（"效果也不是很明显，反应还是要稍微慢一点点，不过倒也能接受"）——
也就是说那几十毫秒不是首字延迟的主要来源，真想再快得去查别处（Mac 侧建 ASR
连接、`STREAM_START` 到首帧的链路）。想改这个取舍只动 `APP_CODEC_IDLE_MS`
一个常量。

两个实现上的坑，改这块前先读：

- **空闲计时必须放在 `handle_tick` 的 `if (!s->screen_on) return;` 之前**：
  "走开不碰设备"恰好就是屏幕已熄的场景，放在 return 之后释放永远等不到。
  `tests/test_app_state.c` 的 `test_codec_idle_release` b 段卡这一点。
- **计时只在归约器出口维护一处**（扫本次产出的动作反推），不在六个
  `STREAM_*` emit 点各写一遍——那六处散在按键、超时、断链、音频错误四条
  路径里，漏一处的症状是"功放悄悄常开"，没有任何报错。

### 关于 `tests/`

上游带一套宿主机测试（`tests/`，8 个可执行，cmake + ctest，不需要 ESP-IDF）：

```bash
cmake -B /tmp/fw-test-build -S tests && cmake --build /tmp/fw-test-build
cd /tmp/fw-test-build && ctest --output-on-failure
```

**改固件后一定要跑。** 本仓库前几轮改动（速记的 `note` 参数、开机态由 HOME
改 READY）都改了被测契约却没跑测试，攒到 2026-09-02 时已经有 4 处编译不过、
4 处断言过期。现在是 8/8 全绿，别再让它烂掉。

### 吉祥物

四种表情对应四种状态，同一个形象：

| 状态 | 表情 |
|---|---|
| 待机 / 就绪 | 微笑站立 |
| 录音中 | 举手 —— "我在听" |
| 识别中 | 抱手歪头 |
| 电脑断连 | 难过 |

素材是 Codex pet（`~/.codex/pets/fantuan/spritesheet.webp`，8×11 网格，单帧 192×208）。
不做逐帧动画：表情本身就是状态指示，比动画更有信息量，也省掉帧缓冲的内存。
四帧缩到 63×104、RGB565A8 格式共 76KB。

需要 alpha 通道——设备背景是蓝天加草地，不透明矩形会切出一个可见方框。

### 待机页的名字

存在设备 NVS 里，不编译进固件，所以这个仓库对任何人都通用，设备换手也不用重刷。
未设置时不画名牌，副标题升为主标题。

```bash
# 通过 USB 控制台设置（SYS 帧或串口 REPL 都行）
owner set LukeLiang
owner            # 查看
owner clear      # 清除
reboot           # 名牌在建页时读一次 NVS，改完要重启
```

`idf.py flash` 不擦 NVS，所以设一次之后后续刷机都会保留。

## 换设备后如何重现

```bash
# 1. 工具链（一次性）
git clone -b v5.5.3 --depth 1 --recursive \
  https://github.com/espressif/esp-idf.git ~/esp/esp-idf
cd ~/esp/esp-idf && ./install.sh esp32c3
brew install cmake ninja        # macOS 上 IDF 不自带这两个

# 2. 固件源码 + 我们的改动
git clone https://github.com/zhaohuaxiaoy/folo-ai-passport-voice /tmp/folo-fw
cd /tmp/folo-fw
git checkout 403ea8e244a3
git apply <此仓库>/device-firmware/patches/*.patch
cp <此仓库>/device-firmware/files/pet_frames.h main/
python3 <此仓库>/device-firmware/tools/gen_pet_frames.py \
    ~/.codex/pets/fantuan/spritesheet.webp > main/pet_frames.c

# 3. 编译
source ~/esp/esp-idf/export.sh
idf.py set-target esp32c3
idf.py build

# 4. 备份新设备的出厂状态（务必先做，见下）
esptool --port /dev/cu.usbmodem* --chip esp32c3 --baud 921600 \
  read-flash 0 0x800000 traecard-factory-8MB.bin

# 5. 刷入
idf.py -p /dev/cu.usbmodem* flash
```

`idf.py flash` 只写 bootloader / 分区表 / app，不碰 NVS，所以设备的
BLE 配对信息和名字会保留。

**不要删 `managed_components/`。** 它看着像构建产物，其实上游把打过补丁的
`espressif__button` 副本提交进了仓库——里面的 `button_adc_set_ignore_until()`
是上电假按键抑制的实现，删掉后重新拉取会得到未打补丁的 4.2.1，链接期报
`undefined reference`。`dependencies.lock` 同理。

## 刷机前必读

**先备份，再刷。** 新设备的 `cardid` 分区（`0x356000`，16KB）里有出厂写入的
`DeviceKey` 和 `DeviceSecret`，是**不可再生**的，官方云端认证要用：

```
folotoy-key / ProductKey : folotoy
DeviceKey                : <设备 MAC，如 4c11ae313d48>
DeviceSecret             : <12 字符密钥>
HardwareVersion          : v1.0.0
```

voice fork 的分区表是 4MB factory（`0x10000`–`0x410000`），**新分区表不再声明
`cardid`**，所以 TRAE CARD 的官方玩法会失效。数据本身不会被物理擦除
（`cardid` 在 `0x356000`，落在 4MB factory 范围内但刷写只覆盖到镜像长度），
但不要指望这一点——单独备份那 16KB 才可靠。

三条回滚路径，按可靠性排序：

1. **自己的全量备份**（第 4 步那份 8MB 镜像）—— 写回即恢复出厂
2. **官方出厂镜像** —— `https://ai-passport.folotoy.cn/assets/firmwares/trae-default/trae_card.bin`
   （版本 1.0.2，manifest 里有 SHA-256 可核对）
3. **BLE Recovery OTA** —— 独立的 `FFF0`–`FFF4` 服务，recovery 分区在
   `0x700000`，不受 app 分区影响

官方自己的文档也说"安装官方玩法会覆盖设备当前的全部内容"，并鼓励用
Codex / Claude Code / TRAE 对着模板仓库改固件——刷机在这个产品里是正常操作。

## 已知问题（未修）

**插着 USB 也会 20 秒关背光、60 秒面板睡眠。** 固件有 `usb_presence` 任务
检测 USB 在位，但没有把它接到休眠策略上（`main/main.c:151`）。有线供电时
不该休眠，改起来是一行的事，等下次刷机时一并处理。

**首字仍比 Mac 键盘触发略慢。** 2026-09-02 为此做了 codec 热态保持
（见「静音与 codec 电源」），实测用户感知差别不明显——说明那几十毫秒的 codec
冷启动不是主因。真要继续查，方向是 Mac 侧收到 `voice.start` 后建 ASR 连接的
耗时，以及 `STREAM_START` 到首帧真正出环的链路，不是设备的 codec。

现状用户可接受，因为交互上是"看到 Mac 上的语音条出现才开口"——延迟被这个
习惯吸收了。
