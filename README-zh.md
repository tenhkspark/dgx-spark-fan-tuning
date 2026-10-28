[English](README.md) | [한국어](README-ko.md) | [简体中文](README-zh.md) | [日本語](README-ja.md)

<sub>`docs/` 下的详细页面为英文；本 README 及其各语言译文包含相同的数字。</sub>

# 4 节点 DGX Spark 集群风扇曲线说明

四节点 DGX Spark（GB10）集群的风扇实际表现、我们最终采用的曲线，以及会悄悄让风扇停转的固件陷阱。我们运行的服务配方（`christopherowen/spark-ds41f`）不附带风扇设置——风扇控制是上游的另一个项目（`christopherowen/dgx-spark-fan-control`）——所以这些数字放在这里。

本仓库是**一个补丁加说明**，不是 fork：

- `patch/0001-performance-curve.patch` — 替换上游用户态控制器中的 `PERFORMANCE_CURVE`。不会改动其他内容；请将其应用到自己的检出副本。
- `docs/` — 曲线、其背后的测量数据，以及应避免的固件版本。
- `scripts/` — 只读快照，以及可放到任意主机上的温度看门狗。
- `deploy/` — 模块自动加载文件和 systemd 单元（其中包含上游基准测试框架所期望的别名）。

```
NVIDIA firmware (EC)  ──►  dgx_ec_fan_control kernel module
                                  │  cooling device: additive "fan floor" state 0..12
                                  ▼
                       dgx-fan-control daemon  (userland, upstream + this patch)
                                  │  every 2s: filtered hottest zone ──► state
                                  ▼
                     fans: state 1 ≈ 2,700 RPM … state 12 = 9,000 / 13,500 RPM
```

## 首先需要了解的故障模式

在我们的四台设备上，加载内核模块但**不运行守护进程**时，两个风扇都停在 **0 RPM**。随后 SoC 热区达到 **96 °C**，平台将 GPU 限制在 **611 MHz**——而 `nvidia-smi` 仍报告 96% 利用率和 8–11 W，且没有 `HW Thermal Slowdown` 标志，因为限制来自 SoC 一侧，而不是 GPU 芯片。两个节点处于该状态时，整个集群慢了两到三倍（prose 34 → 65 tok/s，prefill 2.6K → 6.3K tok/s，结构化输出 86 → 165 tok/s）。

恢复需要**拔掉电源线 30 秒**（EC 复位）。重启无法清除该状态。上游文档称“让服务保持停止，以保留 NVIDIA 的曲线”；这与我们观察到的结果不符，因此请把风扇 RPM 当作需要验证而非假设的对象。

我们据此依赖的两点：

1. 保持守护进程运行（`Restart=always` 语义，见 `deploy/`），并且
2. 让曲线无法请求低于状态 1 的值，这样即使守护进程停止或卡死，也不会留下 0 RPM 的请求（补丁中的 `(0.0, 1)` 条目）。

## 我们运行的曲线

上游请求 `(50°C, 3) (55, 5) (60, 8) (65, 10) (70, 12)`。低于 50 °C 时请求状态 0。我们的补丁在约 62 °C 之前请求更少的冷却，并且从不低于状态 1：

| 滤波后的最热区域 | 本曲线 | 状态 | 常见下限 |
|---|---|---|---|
| < 52 °C | (0.0, 1) | 1 | 2,700 RPM |
| 52 °C | (52.0, 2) | 2 | 3,600 |
| 57 °C | (57.0, 3) | 3 | 4,500 |
| 62 °C | (62.0, 4) | 4 | 5,400 |
| 66 °C | (66.0, 5) | 5 | 6,300 |
| 70 °C | (70.0, 6) | 6 | 7,200 |
| 73 °C | (73.0, 8) | 8 | 9,000 |
| 76 °C | (76.0, 10) | 10 | 11,250 |
| 78 °C 及以上 | (78.0, 12) | 12 | 9,000 / 13,500 |

78 °C 以上全部采用上游最大值，这是有意为之：我们的告警线是 ACPI 78 °C / GPU 75 °C，所以最后 5 °C 刻意保持全速。平滑和速率限制保持与上游一致：`alpha=0.35`，每个 2 s 采样最多 +2 个状态，每个采样 −1 个状态，下降方向有 4 °C 滞回，传输失败时进入状态 12。

把状态理解为一种*请求*：固件会在自身需求和该请求之间取最大值，因此测得的 RPM 是上限包络，而不是表中的值。

## 实测变化

负载测试框架：每个节点并行执行两个 700 token 生成，共六轮，四个节点全部提供服务，前后使用相同提示词。

| 配置 | 空闲 | 中等负载 | 速度 |
|---|---|---|---|
| 守护进程停止（仅加载模块） | 0 RPM，SoC 96 °C，GPU 限制在 611 MHz | — | 比下方慢 2–3× |
| 上游曲线 | 状态 10–12，10,935–13,500 RPM | — | 基线 |
| 本曲线，第一步（+5 °C 偏移） | 状态 3，4,500–5,670 RPM | ACPI 63–69 °C，状态 3–5，4,450–6,300 RPM | 不变 |
| 本曲线，当前（+7 °C 偏移，下限 1） | 状态 2，3,600–4,185 RPM，ACPI 50–53 °C | ACPI 65–73 °C，状态 5–6，5,400–7,200 RPM | 不变（700 tok 10.7–10.9 s，400 tok 5.6 s） |

坦率的取舍：空闲 RPM 下降了约 20%（4,500 → 3,600），中等负载温度上升了约 4 °C，状态升高了一档。相同的工作、相同的芯片，所以平衡点只是沿着“更热但风扇更慢”移动。**在实际负载下，噪声几乎不变**——要真正让 Spark 安静下来，应改善摆放位置（单独房间、柜子、进/排风间隙），而不是调整曲线。

## 固件：不要采用 2026 年 10 月版本集

风扇控制依赖的固件路径已被 2026 年 10 月版本集移除。我们在 2026 年 9 月版本集上测得的结果与 NVIDIA 提供的版本对比如下：

| 组件 | 2026 年 9 月（可用） | 2026 年 10 月（会破坏风扇控制） |
|---|---|---|
| EC | 3.5.8 (`0x03000508`) | 3.13.7 (`0x03000d07`) |
| SoC | 2.155.11 (`0x02009b0b`) | 2.158.15 (`0x02009e0f`) |
| USB-C PD | 5.22 (`0x00000516`) | 5.25 (`0x00000519`) |

在 2026 年 10 月版本集上观察到：下限写入（cmd 3/5）被以 `0xff` 拒绝，读取返回 `0xffff`，override 代码被移除，风扇范围被限制为 975–4,350 RPM，而不是 1,260–9,000 / 1,890–13,500。将新 SoC 与旧 EC 混用同样不可行（继电器超时，tach 0/0），因此没有简单的降级路径。详细信息和我们所使用的冻结步骤见：`docs/firmware.md`。

## 部署

```sh
# 1. module autoload (the cooling device only exists while this is loaded)
sudo install -m 644 deploy/dgx_ec_fan_control.conf /etc/modules-load.d/dgx_ec_fan_control.conf
sudo modprobe dgx_ec_fan_control

# 2. userland controller: upstream checkout + this patch
git clone https://github.com/christopherowen/dgx-spark-fan-control
cd dgx-spark-fan-control && patch -p1 < /path/to/0001-performance-curve.patch
sudo install -m 755 userspace/dgx_fan_control.py /usr/local/sbin/dgx-fan-control

# 3. daemon
sudo install -m 644 deploy/dgx-fan-daemon.service /etc/systemd/system/dgx-fan-daemon.service
#    the upstream benchmark harness stops/starts "dgx-fan-control.service":
#    add the alias so that unit name resolves to the same daemon
sudo ln -sf /etc/systemd/system/dgx-fan-daemon.service /etc/systemd/system/dgx-fan-control.service
sudo systemctl daemon-reload
sudo systemctl enable --now dgx-fan-daemon.service

# 4. verify (this is the step people skip)
scripts/fan-snapshot.sh          # state, hottest zone, both fan RPMs, GPU clock/power
```

省略该别名需自行承担风险：如果 unit 名称无法解析，上游基准测试会以 `cannot restore fan control` 中止，你将完全得不到测量结果。

## 监控

- `scripts/fan-snapshot.sh` — 只读的一次性快照：请求状态、最热温区、`fan1_input`/`fan2_input`、GPU 温度/频率/功耗。可从 cron 安全运行。
- `scripts/thermal-watch.sh` — 当 ACPI ≥ 78 °C、GPU ≥ 75 °C，或**当前**风扇状态读数为 0 时告警。配置项是文件顶部的环境变量（主机列表、ssh 用户、告警文件）。应依据实时状态判断，而不是 `dmesg` 中的 `baseline fan1=` 行：在我们的一台机器上，风扇正常运行时基线却被记录为 0，从而产生了误报。

## 兼容性说明

- 在我们使用内核 `7.0.0-1019-nvidia-64k`（64 KB 页）和 EC 3.5.8 的节点上可用；上游使用相同 EC 验证了 `6.17.0-1029-nvidia`。其他内核以及任何 2026 年 10 月固件均未在此处验证。
- 测量时使用四个节点服务一个张量并行模型；单个空闲节点在温度上表现相同，但由于只有一个 SoC 发热，RPM 平衡点会不同。
- 该曲线是一个*附加下限*。它无法让风扇比固件期望的更安静，也无法超过固件最大值。如果你看到传感器温度不高但风扇固定在最大值，那是固件自身的要求，而不是此补丁造成的。

## 致谢与许可

- `christopherowen/dgx-spark-fan-control` — 此补丁所应用的用户态控制器、内核模块和 systemd unit（GPL-2.0）。仅修改了 `PERFORMANCE_CURVE`。
- `christopherowen/spark-ds41f` — 我们运行的服务配方；它有意将风扇策略留给上述项目。
- 贡献者：**tenhkspark**（测量、曲线、看门狗）和 **DeepSeek V4.1 Flash 1017**（审查与翻译检查，本地运行）。

GPL-2.0，遵循上游 — 参见 [LICENSE](LICENSE)。