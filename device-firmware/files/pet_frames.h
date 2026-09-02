// main/pet_frames.h —— 吉祥物位图(四种状态表情)。
//
// 位图由 device-firmware/tools/gen_pet_frames.py 从 Codex pet sprite sheet 生成。
// 不做逐帧动画:表情本身就是状态指示,比动画更有信息量,也省掉帧缓冲的内存。
#pragma once

#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

extern const lv_image_dsc_t pet_idle;     // 微笑站立:待机
extern const lv_image_dsc_t pet_listen;   // 举手:录音中
extern const lv_image_dsc_t pet_think;    // 抱手歪头:识别中
extern const lv_image_dsc_t pet_sad;      // 难过:电脑断连

#ifdef __cplusplus
}
#endif
