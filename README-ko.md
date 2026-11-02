[English](README.md) | [한국어](README-ko.md) | [简体中文](README-zh.md) | [日本語](README-ja.md)

<sub>`docs/` 아래의 상세 페이지는 영어로 되어 있다. 이 README와 번역본은 동일한 수치를 담는다.</sub>

> **나머지가 있는 곳:** 이 저장소는 GPL-2.0 패치와 팬 측정을 보관합니다.
> 클럭 하한, 서빙, 라우팅, 패치, 워치독과 최신 벤치마크 결과는
> [`dgx-spark-tuning`](https://github.com/tenhkspark/dgx-spark-tuning)에 있습니다.


# 4노드 DGX Spark 클러스터의 팬 커브 노트

4노드 DGX Spark(GB10) 클러스터에서 팬이 실제로 어떻게 동작했는지, 우리가 최종적으로 선택한 커브, 그리고 팬을 조용히 꺼버리는 펌웨어 함정을 정리한다. 우리가 운영하는 서빙 레시피(`christopherowen/spark-ds41f`)는 팬 설정을 포함하지 않는다. 팬 제어는 업스트림의 별도 프로젝트(`christopherowen/dgx-spark-fan-control`)이므로, 이 수치는 이곳에 둔다.

이 저장소는 포크가 아니라 **패치 하나와 노트**다.

- `patch/0001-performance-curve.patch` — 업스트림 사용자 공간 컨트롤러의 `PERFORMANCE_CURVE`를 교체한다. 다른 부분은 건드리지 않는다. 자신의 체크아웃에 적용하면 된다.
- `docs/` — 커브, 그 근거가 된 측정값, 피해야 할 펌웨어 버전.
- `scripts/` — 읽기 전용 스냅샷과 어떤 호스트에도 배치할 수 있는 열 감시기.
- `deploy/` — 모듈 자동 로드 파일과 systemd 유닛(업스트림 벤치마크 하네스가 기대하는 별칭 포함).

```
NVIDIA firmware (EC)  ──►  dgx_ec_fan_control kernel module
                                  │  cooling device: additive "fan floor" state 0..12
                                  ▼
                       dgx-fan-control daemon  (userland, upstream + this patch)
                                  │  every 2s: filtered hottest zone ──► state
                                  ▼
                     fans: state 1 ≈ 2,700 RPM … state 12 = 9,000 / 13,500 RPM
```

## 먼저 알아두어야 할 실패 모드

우리 장비 네 대에서는 데몬을 실행하지 않은 채 커널 모듈만 로드하면 두 팬이 모두 **0 RPM**에 머물렀다. 이어서 SoC 열 영역은 **96 °C**에 도달했고, 플랫폼은 GPU를 **611 MHz**로 제한했다. `nvidia-smi`는 여전히 사용률 96%, 8–11 W를 보고했으며 `HW Thermal Slowdown` 플래그도 없었다. 제한이 GPU 다이가 아니라 SoC 쪽에서 걸리기 때문이다. 그 상태의 노드 두 대 때문에 클러스터 전체가 두세 배 느려졌다(일반 텍스트(prose) 34 → 65 tok/s, prefill 2.6K → 6.3K tok/s, 구조화 출력 86 → 165 tok/s).

복구하려면 **전원 케이블을 30초 동안 뽑아야** 한다(EC 리셋). 재부팅으로는 해소되지 않는다. 업스트림 문서에는 “NVIDIA 커브를 유지하려면 서비스를 중지한 채 두라”고 적혀 있지만, 우리가 관측한 것과 다르다. 따라서 팬 RPM은 가정하지 말고 확인해야 하는 값으로 다뤄야 한다.

우리가 전제로 삼는 두 가지 결과:

1. 데몬을 계속 실행한다(`Restart=always` 의미, `deploy/` 참고).
2. 커브가 상태 1보다 낮은 값을 요청할 수 없게 한다. 그래야 데몬이 중지되거나 멈춰도 0 RPM 요청이 남지 않는다(패치의 `(0.0, 1)` 항목).

## 우리가 사용하는 커브

업스트림은 `(50°C, 3) (55, 5) (60, 8) (65, 10) (70, 12)`를 요청한다. 50 °C 미만에서는 상태 0을 요청한다. 우리 패치는 약 62 °C까지 더 적은 냉각을 요청하며, 상태 1보다 낮은 값은 요청하지 않는다:

| 필터링된 최고 온도 영역 | 이 커브 | 상태 | 공통 하한 |
|---|---|---|---|
| < 52 °C | (0.0, 1) | 1 | 2,700 RPM |
| 52 °C | (52.0, 2) | 2 | 3,600 |
| 57 °C | (57.0, 3) | 3 | 4,500 |
| 62 °C | (62.0, 4) | 4 | 5,400 |
| 66 °C | (66.0, 5) | 5 | 6,300 |
| 70 °C | (70.0, 6) | 6 | 7,200 |
| 73 °C | (73.0, 8) | 8 | 9,000 |
| 76 °C | (76.0, 10) | 10 | 11,250 |
| 78 °C 이상 | (78.0, 12) | 12 | 9,000 / 13,500 |

78 °C 이상은 의도적으로 업스트림 최댓값을 쓴다. 우리 알람 기준선은 ACPI 78 °C / GPU 75 °C이므로, 마지막 5도 구간은 일부러 최고 속도로 둔다. 스무딩과 속도 제한은 업스트림과 동일하다: `alpha=0.35`, 2초 샘플당 최대 +2 상태, 샘플당 −1 상태, 하강 시 4 °C 히스테리시스, 전송 실패 시 상태 12.

상태는 *요청*으로 읽어야 한다. 펌웨어는 자체 요구량과 이 요청 중 최댓값을 사용하므로, 측정된 RPM은 표의 값이 아니라 상위 엔벨로프다.

## 측정된 변화

부하 하네스: 노드당 700토큰 생성 2개를 병렬로, 6회 웨이브, 네 노드 모두 서빙, 전후 동일 프롬프트.

| 구성 | 유휴 | 중간 부하 | 속도 |
|---|---|---|---|
| 데몬 중지(모듈만 로드) | 0 RPM, SoC 96 °C, GPU 611 MHz로 제한 | — | 아래보다 2–3배 느림 |
| 업스트림 커브 | 상태 10–12, 10,935–13,500 RPM | — | 기준선 |
| 이 커브, 첫 단계(+5 °C 이동) | 상태 3, 4,500–5,670 RPM | ACPI 63–69 °C, 상태 3–5, 4,450–6,300 RPM | 변화 없음 |
| 이 커브, 현재(+7 °C 이동, 하한 1) | 상태 2, 3,600–4,185 RPM, ACPI 50–53 °C | ACPI 65–73 °C, 상태 5–6, 5,400–7,200 RPM | 변화 없음(700 tok 10.7–10.9초, 400 tok 5.6초) |

솔직한 트레이드오프는 이렇다. 유휴 RPM은 약 20% 낮아졌고(4,500 → 3,600), 중간 부하 온도는 대략 4 °C 올라갔으며 상태는 한 단계 높아졌다. 같은 작업, 같은 실리콘이므로 평형점이 “더 뜨겁지만 더 느린 팬” 쪽으로 이동한 것뿐이다. **실제 부하에서는 소음이 거의 변하지 않는다.** Spark의 소음을 실제로 줄이려면 커브보다 배치(별도 방, 캐비닛, 흡기/배기 여유)를 손봐야 한다.

## 펌웨어: 2026년 10월 세트는 피할 것

팬 제어는 10월 세트에서 제거된 펌웨어 경로에 의존한다. 9월 세트에서 측정한 값과 NVIDIA가 제공한 값은 다음과 같다:

| 구성 요소 | 2026년 9월(정상 동작) | 2026년 10월(팬 제어 불가) |
|---|---|---|
| EC | 3.5.8 (`0x03000508`) | 3.13.7 (`0x03000d07`) |
| SoC | 2.155.11 (`0x02009b0b`) | 2.158.15 (`0x02009e0f`) |
| USB-C PD | 5.22 (`0x00000516`) | 5.25 (`0x00000519`) |

10월 세트에서 관측한 내용: 하한 쓰기(cmd 3/5)는 `0xff`로 거부되고, 읽기는 `0xffff`를 반환하며, 오버라이드 코드는 제거되었고, 팬 범위는 1,260–9,000 / 1,890–13,500 대신 975–4,350 RPM으로 제한되었다. 새 SoC와 구 EC를 섞는 방법도 동작하지 않는다(릴레이 타임아웃, tach 0/0). 따라서 쉬운 다운그레이드 경로는 없다. 세부 내용과 우리가 사용한 고정 절차: `docs/firmware.md`.

## 배포

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

별칭을 생략하면 책임은 본인에게 있다. 유닛 이름이 해석되지 않으면 업스트림 벤치마크는 `cannot restore fan control`과 함께 중단되고, 측정값은 전혀 얻지 못한다.

## 두 번째 조용한 고장: 데몬이 죽고 팬은 낮은 상태로 계속 돈다

2026-10-31 우리 노드 하나에서 실측했다. `cur_state` 쓰기가 타임아웃(`Errno 110`)되어
데몬이 종료 코드 69로 죽었고, 업스트림 유닛의 `RestartPreventExitStatus=69` 때문에 systemd는
**재시작하지 않도록** 설정되어 있었다. EC는 팬을 낮은 하한에 붙잡아 두었고
(3780 / 5400 RPM, 정상 노드는 9000 / 12690), GPU는 66 °C, 가장 뜨거운 영역은 73 °C였다 —
**세 경보 임계값 모두 아래**였으므로 1일 19시간 동안 아무 경보도 울리지 않았다.
`systemctl restart dgx-fan-daemon`으로 약 7,200 RPM, 63 °C로 1분 안에 돌아왔다.

`deploy/`의 유닛은 처음부터 그 줄이 없었고(`Restart=always`),
`scripts/thermal-watch.sh`는 이제 **유닛이 `active`가 아닌 시점**에 경보한다.
확인: `systemctl show -p Restart -p RestartPreventExitStatus dgx-fan-daemon` — 두 번째 값이 비어 있어야 한다.

## 모니터링

- `scripts/fan-snapshot.sh` — 읽기 전용 1회 실행: 요청 상태, 가장 뜨거운 열 영역, `fan1_input`/`fan2_input`, GPU 온도/클록/전력. cron에서 실행해도 안전하다.
- `scripts/thermal-watch.sh` — 데몬 유닛이 `active`가 아닐 때, ACPI ≥ 78 °C, GPU ≥ 75 °C 또는 **현재** 팬 상태가 0으로 읽힐 때 알람을 발생시킨다. 설정은 파일 상단의 환경 변수다(호스트 목록, ssh 사용자, 알람 파일, 유닛 이름). `dmesg`의 `baseline fan1=` 줄이 아니라 실시간 상태를 기준으로 판단해야 한다. 우리 장비 중 하나에서는 팬이 정상 동작 중인데도 기준선이 0으로 기록되어 거짓 알람이 발생했다.

## 호환성 참고 사항

- 우리 노드에서는 커널 `7.0.0-1019-nvidia-64k`(64 KB 페이지)와 EC 3.5.8에서 동작한다. 업스트림은 동일한 EC에서 `6.17.0-1029-nvidia`를 검증했다. 다른 커널과 모든 10월 펌웨어는 이 저장소에서 검증되지 않았다.
- 네 노드가 하나의 텐서 병렬 모델을 서빙하는 구성에서 측정했다. 단일 유휴 노드는 온도 측면에서 동일하게 동작하지만, 뜨거운 SoC가 하나뿐이므로 RPM 평형점은 달라진다.
- 이 커브는 *가산 하한*이다. 펌웨어가 원하는 것보다 팬을 더 조용하게 만들 수 없고, 펌웨어 최댓값을 넘을 수도 없다. 센서가 시원한데 팬이 최고 속도에 고정되어 있다면, 그것은 이 패치가 아니라 펌웨어 자체의 요구량이다.

## 크레딧 및 라이선스

- `christopherowen/dgx-spark-fan-control` — 이 패치가 적용되는 사용자 공간 컨트롤러, 커널 모듈, systemd 유닛(GPL-2.0). 변경되는 것은 `PERFORMANCE_CURVE`뿐이다.
- `christopherowen/spark-ds41f` — 우리가 운영하는 서빙 레시피. 팬 정책은 의도적으로 위 프로젝트에 맡긴다.
- 기여자: **tenhkspark**(측정, 커브, 워치독) 및 **DeepSeek V4.1 Flash 1017**(검토 및 번역 확인, 로컬 실행).

GPL-2.0, 업스트림을 따름 — [LICENSE](LICENSE) 참고.