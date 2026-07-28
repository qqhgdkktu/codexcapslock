# Codex + Claude Code MagSafe / Caps Lock Indicator

[![CI](https://github.com/qqhgdkktu/codexcapslock/actions/workflows/ci.yml/badge.svg)](https://github.com/qqhgdkktu/codexcapslock/actions/workflows/ci.yml)

Нативный аппаратный индикатор задач Codex и Claude Code для MacBook:

- подключённый и управляемый MagSafe 3 имеет приоритет;
- без MagSafe используется только LED встроенной клавиши Caps Lock;
- логический Caps Lock и регистр набора никогда не переключаются ради индикации.

Версия 2.0 обрабатывает только штатные lifecycle hooks. Она не читает
transcript, текст запросов, ответы, команды, пути к сессиям или локальные логи
агентов, не использует сеть и не требует Accessibility или Input Monitoring.

## Быстрый старт

Требования:

- macOS 14 или новее;
- Python 3.10 или новее;
- Swift 6.2 или новее;
- Codex и/или Claude Code;
- MacBook со встроенной клавиатурой и физическим LED Caps Lock.

```bash
git clone https://github.com/qqhgdkktu/codexcapslock.git
cd codexcapslock
python3 scripts/install.py
```

Если нужен полностью непривилегированный пробный режим:

```bash
python3 scripts/install.py --caps-lock-only
```

Он не устанавливает root-helper и не показывает окно администратора. Режим
`--auto` используется по умолчанию; `--magsafe` требует доступный MagSafe и
завершает установку ошибкой, если его нет. Перед изменениями можно выполнить
`python3 scripts/install.py --dry-run`.

Обычная установка на MacBook с MagSafe один раз показывает защищённое окно
администратора для небольшого локального helper. Helper имеет фиксированный
протокол только для ключа `ACLC`, принимает соединение лишь от root или
активного консольного пользователя и возвращает MagSafe в системный режим при
старте, потере соединения, смене пользователя или истечении lease.

## Состояния

| Состояние | Выбранный LED |
| --- | --- |
| Агент работает | MagSafe использует firmware slow blink; Caps Lock мигает 0,5/0,5 с |
| Агент ждёт ответа или разрешения | Горит постоянно |
| Есть непросмотренное завершение | Горит постоянно |
| Активных и завершённых задач нет | MagSafe возвращён в `system`, Caps Lock — к реальному состоянию |

При нескольких сессиях первое завершение имеет приоритет над ожиданием и
работой. Очередь сохраняется после перезапуска, а повторные, запоздалые,
несогласованные по turn/call ID и слишком старые события не меняют состояние.
Один `ack` снимает только голову очереди.

```bash
~/.local/bin/codex-capslock-indicator status
~/.local/bin/codex-capslock-indicator status --json
~/.local/bin/codex-capslock-indicator ack
~/.local/bin/codex-capslock-indicator ack COMPLETION_ID
~/.local/bin/codex-capslock-indicator ack --all
```

В режиме Caps Lock уведомление о завершении также можно подтвердить физическим
переходом Caps Lock; программа сразу возвращает логический Caps Lock в
выключенное состояние. Завершение Codex можно подтвердить, оставив Codex
активным минимум на секунду после обязательного времени видимости. На MagSafe
Caps Lock работает полностью обычно и не служит кнопкой подтверждения.

## Безопасная установка и удаление

Установщик выполняет preflight, тесты и release-сборку, создаёт приватную
резервную копию (`0700/0600`), берёт общий install-lock, точно добавляет только
свои hooks, атомарно изменяет JSON-конфигурацию и откатывает пользовательские
файлы при ошибке. Root-часть сначала помещается в staging, проверяется по
SHA-256 и только затем заменяет прежний helper.

```bash
python3 scripts/uninstall.py --dry-run
python3 scripts/uninstall.py
python3 scripts/uninstall.py --purge
```

Обычное удаление сохраняет runtime и backups. `--purge` дополнительно удаляет
их после успешного удаления бинарника, LaunchAgent, helper и точного набора
managed hooks. Чужие hooks, `notify` и остальные настройки не удаляются.

## Проверка

```bash
~/.local/bin/codex-capslock-indicator --version
~/.local/bin/codex-capslock-indicator status
~/.local/bin/codex-capslock-indicator self-test
~/.local/bin/codex-capslock-indicator inspect-led
~/.local/bin/codex-capslock-indicator inspect-magsafe
```

`self-test` и `demo` идут через уже запущенный daemon, поэтому одновременно
управлять одним LED из двух процессов нельзя. После проверки оба выхода
восстанавливаются.

Для проверки исходников:

```bash
swift test
swift build -c release
python3 -m unittest discover -s scripts/tests
git diff --check
```

Подробное руководство: [docs/USAGE.md](docs/USAGE.md). Правила работы с
репозиторием: [AGENTS.md](AGENTS.md). Сообщение об уязвимости:
[SECURITY.md](SECURITY.md).

## Архитектура и границы

- Hooks преобразуются в versioned semantic events с ограниченными
  идентификаторами и размером.
- Online-события идут через приватный UNIX socket; при недоступном daemon
  используется ограниченный 4 MiB spool.
- Durable snapshot хранит только lifecycle metadata и неизменяемую очередь
  завершений.
- Один daemon владеет обоими аппаратными выходами; CLI maintenance-команды
  маршрутизируются через его control socket.
- MagSafe helper использует protocol v2 с lease heartbeat, readback и
  allowlist режимов.
- LaunchAgent перезапускает daemon только после аварийного завершения; без
  активных или непросмотренных задач daemon сам завершается.

Управление MagSafe основано на недокументированном SMC-ключе `ACLC`, поэтому
после крупного обновления macOS или firmware нужна реальная проверка
`self-test`. При недоступном MagSafe программа безопасно использует Caps Lock.
Основа SMC-части — MIT-проект
[MagSafe Dark](https://github.com/bulava92/magsafe-dark); уведомление приведено
в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
