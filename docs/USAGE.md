# Использование Codex + Claude Code MagSafe / Caps Lock Indicator 2.0

## Что делает индикатор

Программа использует ровно один аппаратный LED:

1. Подключён физический MagSafe 3 и отвечает helper — работает MagSafe.
2. Иначе работает LED Caps Lock встроенной клавиатуры.

USB-C-питание не считается MagSafe. В режиме Caps Lock физический LED
управляется отдельно от логического Caps Lock. В режиме MagSafe клавиша и LED
Caps Lock полностью принадлежат macOS.

| Ситуация | LED | Действие |
| --- | --- | --- |
| Codex или Claude Code работает | Мигает | Ничего |
| Агент ждёт ответа или разрешения | Горит | Ответить в нужной сессии |
| Есть непросмотренное завершение | Горит | Подтвердить завершение |
| Очередь пуста и активных сессий нет | Обычная системная индикация | Ничего |

## Требования

- macOS 14+;
- Python 3.10+;
- Swift 6.2+ из Xcode или Xcode Command Line Tools;
- установленный `codex` и/или `claude`;
- встроенная клавиатура MacBook с физическим LED Caps Lock.

MagSafe дополнительно требует Apple Silicon и физический порт MagSafe 3.

```bash
codex --version      # если используется Codex
claude --version     # если используется Claude Code
swift --version
python3 --version
```

## Установка

```bash
git clone https://github.com/qqhgdkktu/codexcapslock.git
cd codexcapslock
python3 scripts/install.py
```

Варианты:

```bash
python3 scripts/install.py --dry-run
python3 scripts/install.py --caps-lock-only
python3 scripts/install.py --auto
python3 scripts/install.py --magsafe
python3 scripts/install.py --no-hardware-test
```

- `--caps-lock-only` не устанавливает root-helper и не запрашивает пароль.
- `--auto` — значение по умолчанию: MagSafe при наличии, иначе Caps Lock.
- `--magsafe` требует MagSafe и прекращает установку при его отсутствии.
- `--no-hardware-test` предназначен для managed environments и оставляет
  аппаратную часть непроверенной.

Установщик сначала выполняет preflight, Swift-тесты и release-сборку. Затем он
создаёт приватную резервную копию, берёт глобальный lock, останавливает прежний
LaunchAgent, атомарно заменяет файлы, добавляет exact hooks, проверяет хеш
бинарника и запускает один crash-supervised daemon. При ошибке пользовательские
файлы возвращаются из transaction snapshot.

Для MagSafe root-файлы сначала копируются в root-owned staging, проверяются по
SHA-256 и только потом заменяют прежнюю пару helper/plist. Ошибка после начала
commit возвращает предыдущую пару.

После успешной установки проверьте вывод:

```bash
~/.local/bin/codex-capslock-indicator --version
~/.local/bin/codex-capslock-indicator status
~/.local/bin/codex-capslock-indicator self-test
~/.local/bin/codex-capslock-indicator inspect-magsafe
```

Установщик печатает путь к backup. Файл
`~/Library/Application Support/CodexCapsLockIndicator/installation.json`
содержит версию, выбранный output, хеши и число managed hooks, но не данные
задач.

## Lifecycle и очередь

Codex и Claude Code передают события `UserPromptSubmit`, `PreToolUse`,
`PermissionRequest`, `PostToolUse`, `Stop` и `SessionEnd`. Claude Code также
использует `Notification(permission_prompt)`, `PostToolUseFailure` и
`StopFailure`.

Событие содержит только:

- версию схемы и уникальный event ID;
- агент;
- ограниченные session/turn/call ID;
- тип lifecycle-события и время.

Daemon проверяет causal generation, turn/call correlation, возраст события и
идемпотентность. Старое событие не может отменить более новое завершение.
`SessionEnd` не удаляет непросмотренный результат. Очередь сохраняется атомарно
и переживает перезапуск.

Основной путь — приватный UNIX socket `0600`. Если daemon ещё не отвечает,
hook дописывает событие в bounded spool размером не более 4 MiB. Daemon сначала
сохраняет новый snapshot и лишь затем компактизирует прочитанный spool.

## Подтверждение завершений

```bash
# только первое завершение
~/.local/bin/codex-capslock-indicator ack

# только голову очереди с этим ID
~/.local/bin/codex-capslock-indicator ack COMPLETION_ID

# всю очередь
~/.local/bin/codex-capslock-indicator ack --all
```

ID головы виден в `status` и `status --json`. Указанный ID снимается только
если он по-прежнему является головой очереди; это защищает от подтверждения не
того результата.

Когда выбран Caps Lock, физический переход клавиши также подтверждает голову
очереди и гарантированно оставляет логический Caps Lock выключенным. Когда
выбран MagSafe, Caps Lock работает обычно и не подтверждает задачу. Codex можно
подтвердить, оставив приложение на переднем плане после минимального времени
видимости. Фокус терминала для Claude Code намеренно не отслеживается.

## Команды

| Команда | Назначение |
| --- | --- |
| `--version` | Версия |
| `status [--json]` | Состояние, output, очередь, protocol и оборудование |
| `ack [ID\|--all]` | Точное подтверждение завершений |
| `inspect-led` | Физический LED и логический Caps Lock |
| `inspect-magsafe` | Порт, питание, helper и значение `ACLC` |
| `self-test` | Самовосстанавливающаяся проверка оборудования |
| `demo` | Короткая самовосстанавливающаяся демонстрация |
| `repair` | Вернуть оба LED в системное состояние и согласовать текущий output |

`hook`, `led`, `raw-led` и `magsafe` — lifecycle internals или
низкоуровневая диагностика. При работающем daemon аппаратные команды либо идут
через его control socket, либо отклоняются: второго владельца LED нет.

## Диагностика

### `status` ещё недоступен

Отправьте задачу в Codex или Claude Code. Hook запустит LaunchAgent. Status
считается валидным только при свежем timestamp, живом PID и удерживаемом
singleton-lock, поэтому старый файл после crash не выдаётся за рабочий daemon.

### MagSafe подключён, но выбран Caps Lock

```bash
~/.local/bin/codex-capslock-indicator inspect-magsafe
~/.local/bin/codex-capslock-indicator status
```

Нужны физический type-17 port, `ConnectionActive`, текущее внешнее питание и
отвечающий protocol-v2 helper. При любой ошибке безопасный fallback — Caps
Lock.

### Проверка Claude Code без аккаунта

```bash
swift test
python3 -m unittest discover -s scripts/tests
```

`MultiAgentLifecycleTests` воспроизводит официальные Claude hook JSON через
реальный writer/reducer и проверяет очередь вместе с Codex. Это не заменяет
фактическое событие `Stop` из живого Claude Code аккаунта.

## Обновление и удаление

```bash
git pull --ff-only
python3 scripts/install.py
```

Для удаления:

```bash
python3 scripts/uninstall.py --dry-run
python3 scripts/uninstall.py
python3 scripts/uninstall.py --purge
```

Удаление останавливает daemon, возвращает оба LED под управление macOS,
удаляет только exact managed hooks и проверяет постусловия. Без `--purge`
runtime и backups сохраняются. С `--purge` они удаляются только после успешного
завершения основного удаления.

Не заменяйте вручную целиком `~/.codex/hooks.json` или
`~/.claude/settings.json`: в них могут быть настройки других инструментов.

## Приватность и безопасность

- Transcript, prompt, answer, команды, tool arguments и пути к сессиям не
  читаются и не сохраняются runtime-контуром.
- Размер stdin hook, идентификаторов, record, socket message и spool ограничен.
- Runtime и socket принадлежат текущему пользователю; каталоги имеют `0700`,
  файлы — `0600`; symlink и не-regular файлы отклоняются.
- Нет сети, telemetry, analytics, окон, GPU-работы, global keyboard tap,
  Accessibility или Input Monitoring.
- Root-helper не выполняет shell/file/network операции и принимает только
  фиксированные MagSafe-команды protocol v2.
- Lease возвращает `ACLC=system` после crash, disconnect, timeout или смены
  активного пользователя.

Политика раскрытия уязвимостей описана в [SECURITY.md](../SECURITY.md).

## Ограничение MagSafe

`ACLC` — недокументированный SMC-ключ. После обновления macOS или firmware
запустите `self-test`. Если контроль недоступен, программа автоматически
использует Caps Lock.
