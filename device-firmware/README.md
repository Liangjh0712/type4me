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

## 我们的改动

`patches/` 下按顺序应用，`files/` 是要拷进固件的新文件：

| 文件 | 内容 |
|---|---|
| `patches/0001-quiet-device-ui.patch` | 重做屏幕：文案改正常大小写、每状态一个吉祥物表情、底部只留当前用得到的那条提示、顶栏加连接方式图标；待机页名牌显示主人名字（读自设备 NVS，见下）。 |
| `files/pet_frames.h` | 吉祥物位图的声明（手写，要拷进 `main/`）。 |
| `tools/gen_pet_frames.py` | 从 Codex pet sprite sheet 生成 `main/pet_frames.c`。位图是生成物，不入库——493KB 的 C 数组没必要进 git，改表情改脚本里的 `PICKS` 表重新生成即可。 |

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
