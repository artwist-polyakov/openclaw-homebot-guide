# OpenClaw HomeBot — Администрирование

## Сервер

- **Хостинг:** VDSina, Ubuntu 22.04, 2GB RAM, 30GB диск
- **IP:** см. SSH-скилл (`config/.env`)
- **Docker:** 24.0.7 + Compose 2.21.0

## Структура на сервере

```
/opt/openclaw/
├── docker-compose.yml          # Docker-конфиг (порты, env, образ)
├── update.sh                   # Скрипт автообновления
├── vv-mcp-client.py            # Persistent MCP-клиент ВкусВилл (порт 18791)
├── config/
│   ├── openclaw.json           # Главный конфиг (модель, каналы, безопасность)
│   ├── agents/main/agent/
│   │   └── auth-profiles.json  # API-ключ LLM-провайдера
│   ├── agents/<agent-name>/    # Доп. агенты (свои сессии, agent/)
│   │   ├── agent/
│   │   └── sessions/
│   ├── credentials/            # Telegram allowlists, pairing
│   ├── agents/main/sessions/   # Сессии (история чатов)
│   ├── workspace-<agent-name>/ # Workspace доп. агента (AGENTS.md, skills/ и т.д.)
│   └── scheduler/              # Задачи планировщика
│       ├── tasks-main.json     # Задачи для агента main
│       └── tasks-<agent-name>.json  # Задачи для доп. агента
├── scheduler/
│   ├── scheduler-daemon.py     # Демон-планировщик (systemd)
│   └── scheduler.sh            # CLI для управления задачами (копируется в workspace каждого агента)
├── workspace/                  # Workspace агента main
│   ├── AGENTS.md               # Персона бота (тон, поведение, правила)
│   ├── SOUL.md                 # Характер, границы, security rules
│   ├── USER.md                 # Профили членов семьи
│   ├── MEMORY.md               # Долгосрочная память (предпочтения, даты)
│   ├── IDENTITY.md             # Имя и эмодзи
│   ├── HEARTBEAT.md            # Периодические задачи + самоочистка
│   ├── TOOLS.md                # Заметки по форматированию
│   └── skills/vkusvill/
│       ├── SKILL.md            # Инструкция для бота по ВкусВилл
│       └── vkusvill.sh         # Скрипт-обёртка (вызывает vv-mcp-client + Puppeteer)
└── repo/                       # Клон github.com/openclaw/openclaw
```

## Повседневные операции

### Поменять поведение бота
```bash
nano /opt/openclaw/workspace/AGENTS.md
docker restart openclaw-gateway
```

### Поменять модель
```bash
# В /opt/openclaw/config/openclaw.json поменять agents.defaults.model.primary
# Текущая: kimi-coding/k2p5 (Kimi Coding, Anthropic-совместимый API)
# Доступные Anthropic: anthropic/claude-opus-4-6, anthropic/claude-sonnet-4-5, anthropic/claude-haiku-4-5
# Для Anthropic: заменить KIMI_API_KEY на ANTHROPIC_API_KEY в .env
nano /opt/openclaw/config/openclaw.json
docker restart openclaw-gateway
```

### Посмотреть логи
```bash
docker logs openclaw-gateway --tail 50
docker logs openclaw-gateway -f          # следить в реальном времени
```

### Перезапустить бота
```bash
docker restart openclaw-gateway
```

### Остановить / запустить
```bash
cd /opt/openclaw && docker compose stop openclaw-gateway
cd /opt/openclaw && docker compose up -d openclaw-gateway
```

### Пересобрать образ (после обновления репо)
```bash
cd /opt/openclaw/repo && git pull && docker build -t openclaw:local -f Dockerfile .
docker restart openclaw-gateway
```

## Telegram

- **Бот:** @yourbotname
- **DM Policy:** allowlist (только пользователи из списка)
- **Группы:** отвечает только на @упоминания и реплаи

### Одобрить нового пользователя
```bash
docker exec openclaw-gateway node dist/index.js pairing approve telegram <КОД>
```

### Добавить бота в группу
1. Добавить @yourbotname в группу
2. Сделать админом (чтобы видел все сообщения) или отключить Privacy Mode через @BotFather → /setprivacy → Disable
3. Тегать через @yourbotname для вызова

### Ограничить конкретной группой
В `openclaw.json` заменить `"*"` на ID группы:
```json
"groups": {
  "-1001234567890": {
    "requireMention": true
  }
}
```

## Multi-agent (несколько агентов)

OpenClaw поддерживает несколько агентов в одном инстансе. Каждый агент — изолированная сущность со своими сессиями, workspace, моделью и целевым чатом.

### Зачем

- Разные задачи — разные агенты (например, один для продуктов, другой для семейных финансов)
- Разные группы в Telegram → разные агенты с отдельным контекстом
- Разные модели (один агент на дешёвой модели для рутины, другой на сильной для сложного)

### Как добавить второго агента

1. **Workspace** — создать отдельную директорию с bootstrap-файлами:
```bash
mkdir -p /opt/openclaw/config/workspace-<agent-name>
# Создать: AGENTS.md, IDENTITY.md, HEARTBEAT.md и т.д.
```

2. **Объявить агента в `openclaw.json`** → `agents.list`:
```json
{
  "agents": {
    "list": [
      {
        "id": "main",
        "default": true,
        "name": "HomeHelper"
      },
      {
        "id": "<agent-name>",
        "name": "SecondAgent",
        "workspace": "~/.openclaw/workspace-<agent-name>",
        "model": { "primary": "kimi-coding/k2p5" },
        "heartbeat": {
          "every": "15m",
          "target": "telegram",
          "to": "<group-chat-id>",
          "activeHours": { "start": "08:00", "end": "23:00", "timezone": "Europe/Moscow" }
        }
      }
    ]
  }
}
```

3. **Binding** — привязать группу к агенту:
```json
{
  "bindings": [
    {
      "agentId": "<agent-name>",
      "match": {
        "channel": "telegram",
        "peer": { "kind": "group", "id": "<group-chat-id>" }
      }
    }
  ]
}
```
Все сообщения из этой группы пойдут к нужному агенту. `main` остаётся дефолтным для всех остальных чатов.

4. **Hooks API** — разрешить обоих агентов:
```json
{
  "hooks": {
    "enabled": true,
    "token": "<hooks-token>",
    "allowedAgentIds": ["main", "<agent-name>"]
  }
}
```

5. **Volume mount** — добавить в `docker-compose.yml`:
```yaml
volumes:
  - /opt/openclaw/config/workspace-<agent-name>:/home/node/.openclaw/workspace-<agent-name>
```

6. **Рестарт:**
```bash
cd /opt/openclaw && docker compose down && docker compose up -d openclaw-gateway
```

### Per-agent allowlists

Каждый агент наследует общие `allowFrom` / `groupAllowFrom`. Binding определяет только маршрутизацию, а не доступ. Пользователи из allowlist могут писать любому агенту напрямую через hooks API (с указанием `agentId`).

### Пути workspace (host → Docker)

| Агент | Host | Docker |
|-------|------|--------|
| main | `/opt/openclaw/workspace/` | `/home/node/.openclaw/workspace/` |
| \<agent-name\> | `/opt/openclaw/config/workspace-<agent-name>/` | `/home/node/.openclaw/workspace-<agent-name>/` |

---

## Scheduler (планировщик задач)

Внешний демон, который запускает задачи по расписанию через hooks API OpenClaw. В отличие от встроенного heartbeat (периодический, нельзя задать точное время), scheduler поддерживает cron-выражения и одноразовые события.

### Архитектура

```
┌─────────────────────┐     POST /hooks/agent     ┌──────────────────┐
│  scheduler-daemon.py │ ──────────────────────── │  OpenClaw Gateway │
│  (systemd на хосте)  │     127.0.0.1:18789      │  (Docker)         │
└─────────────────────┘                            └──────────────────┘
         │
         │ читает
         ▼
   config/scheduler/
   ├── tasks-main.json
   └── tasks-<agent-name>.json
```

- **systemd-сервис** на хосте (вне Docker)
- Проверяет задачи каждые 30 секунд, дедупликация до 1 раза в минуту (против двойного срабатывания cron)
- Сканирует `tasks-*.json` в директории — один файл на каждого агента
- Зависимости: только Python 3 stdlib (без pip)
- Часовой пояс: Europe/Moscow (UTC+3)

### Формат файла задач

`config/scheduler/tasks-<agent-id>.json`:

```json
{
  "version": 1,
  "tasks": [
    {
      "id": "a1b2c3d4",
      "name": "Напомни проверить задачи",
      "prompt": "Проверь HEARTBEAT.md и напомни если есть активные задачи",
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * 1-5"
      },
      "enabled": true,
      "agentId": "<agent-id>",
      "channel": "telegram",
      "to": "<group-chat-id>",
      "runCount": 0,
      "lastRunAt": null,
      "maxRuns": null,
      "timeoutSeconds": 120
    }
  ]
}
```

**Виды расписаний (`schedule.kind`):**

| Kind | Формат | Пример |
|------|--------|--------|
| `cron` | 5-полей (мин час дм мес дн) | `"0 9 * * *"` — каждый день в 9:00 |
| `every` | `everySeconds: N` | `"everySeconds": 3600` — каждый час |
| `at` | ISO 8601 | `"2026-03-01T10:00"` — одноразово |

Одноразовые (`at`) задачи автоматически отключаются после выполнения. Задачи с `maxRuns` отключаются после N запусков.

### CLI (scheduler.sh)

Скрипт `scheduler.sh` разворачивается в workspace каждого агента как скилл. Бот может управлять расписанием через этот инструмент.

```bash
scheduler.sh list                          # Показать все задачи
scheduler.sh add --name "..." --cron "0 9 * * *" --prompt "..." \
  [--agent main] [--channel telegram] [--to "<chat-id>"] [--max-runs 5]
scheduler.sh add --name "..." --every 3600 --prompt "..."
scheduler.sh add --name "..." --at "2026-03-01T10:00" --prompt "..."
scheduler.sh remove --id "a1b2c3d4"
scheduler.sh enable --id "a1b2c3d4"
scheduler.sh disable --id "a1b2c3d4"
scheduler.sh status                        # Кол-во задач + статус демона
```

### Systemd

```ini
[Unit]
Description=OpenClaw Scheduler Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/openclaw/scheduler/scheduler-daemon.py
Environment=SCHEDULER_TASKS_DIR=/opt/openclaw/config/scheduler
Environment=SCHEDULER_GATEWAY=http://127.0.0.1:18789
Environment=SCHEDULER_HOOKS_TOKEN=<hooks-token>
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
systemctl enable scheduler-daemon
systemctl start scheduler-daemon
journalctl -u scheduler-daemon -f   # логи
```

### Права на файлы задач

Файлы в `config/scheduler/` должны быть доступны и демону (root/systemd), и Docker-контейнеру (claudeuser, uid=1000):

```bash
chown -R 1000:1000 /opt/openclaw/config/scheduler/
chmod 755 /opt/openclaw/config/scheduler/
chmod 644 /opt/openclaw/config/scheduler/tasks-*.json
```

---

## Веб-админка

Доступна через SSH-туннель:
```bash
ssh -L 18789:127.0.0.1:18789 <user>@<IP-сервера>
```
Или через Port Forwarding в Termius (Local 18789 → Remote 127.0.0.1:18789).

Открыть: http://localhost:18789

Gateway token: значение из `openclaw.json` → `gateway.auth.token` (или `OPENCLAW_GATEWAY_TOKEN` из `.env`).

## Heartbeat (автопробуждение)

Бот просыпается каждые 15 мин (08:00–23:00 МСК), проверяет `HEARTBEAT.md` и реагирует если есть задачи. Алерты идут в последний активный чат. Настройка в `openclaw.json`:
```json
"heartbeat": {
  "every": "15m",
  "target": "last",
  "activeHours": {
    "start": "08:00",
    "end": "23:00",
    "timezone": "Europe/Moscow"
  }
}
```
`HEARTBEAT_OK` — не доставляется (нет спама). Алерт уходит только когда бот решил что-то сообщить.

## Безопасность

| Настройка | Значение | Где |
|-----------|----------|-----|
| Gateway bind | loopback (только localhost) | docker-compose.yml |
| Gateway auth | token | openclaw.json |
| DM policy | allowlist | openclaw.json |
| DM scope | per-channel-peer (изоляция сессий) | openclaw.json |
| Группы | requireMention: true | openclaw.json |
| Tools write/edit | разрешены (бот может писать в workspace) | openclaw.json |
| Sandbox | off (внутри Docker) | openclaw.json |
| mDNS | off | openclaw.json |
| Модель | kimi-coding/k2p5 | openclaw.json |
| Security rule | SOUL.md запрещает показ токенов в чатах | SOUL.md |

> **`--network host` и внешние hooks.** Если scheduler-daemon (или другой внешний клиент) вызывает hooks API на `127.0.0.1:18789`, а контейнер запущен в bridge mode — gateway внутри контейнера биндится на `127.0.0.1` **внутри своего network namespace**, и хостовый `127.0.0.1` до него не добирается. Симптом: `Broken pipe` / `Empty reply from server`. Решение: запускать контейнер с `--network host` (или с `-p 127.0.0.1:18789:18789` при bridge mode, если gateway биндит `0.0.0.0` внутри). С `--network host` контейнер делит сетевой стек с хостом — `127.0.0.1` один и тот же.

### Изоляция DM-сессий

Настройка `session.dmScope: "per-channel-peer"` изолирует контекст личных сообщений по связке "канал + отправитель". Без этого при нескольких пользователях возможна утечка контекста между людьми (cross-user leakage) — модель может "подтянуть" куски чужой переписки.

### Ежедневный сброс сессий

Сессии автоматически сбрасываются в 4:00 МСК. Бот перечитывает все bootstrap-файлы (AGENTS.md, SOUL.md, HEARTBEAT.md и т.д.) при первом сообщении после сброса. Без этого изменения в bootstrap-файлах не применяются до ручного рестарта.

```json
"session": {
  "dmScope": "per-channel-peer",
  "reset": {
    "mode": "daily",
    "atHour": 4
  }
}
```

## Автоматизация (cron)

| Задача | Расписание (МСК) | Команда |
|--------|-----------------|---------|
| Docker prune | Вс 4:00 | `docker system prune -af --filter "until=168h"` |
| Обновление OpenClaw | Пн 5:00 | `/opt/openclaw/update.sh` |
| VV-checker keepalive | Ежедневно 10:00 | `curl -s http://127.0.0.1:18790/check?url=...` |
| VV MCP Client | systemd (always) | `vv-mcp-client.service` — авторестарт |

Логи: `/var/log/docker-prune.log`, `/var/log/openclaw-update.log`

## Секреты (.env)

Все ключи хранятся в `/opt/openclaw/.env` (chmod 600):
```
OPENCLAW_GATEWAY_TOKEN=...
TELEGRAM_BOT_TOKEN=...
KIMI_API_KEY=...
PERPLEXITY_API_KEY=...
OPENAI_API_KEY=...
TZ=Europe/Moscow
```

Docker-compose подтягивает через `env_file: .env`. **Важно:** при изменении `.env` нужен `docker compose down && docker compose up -d openclaw-gateway` (не просто `docker restart` — он не перечитывает env).

## Провайдер LLM

Текущий: **Kimi Coding** (`kimi-coding/k2p5`) — встроенный провайдер OpenClaw.

### Как настроен Kimi Coding

Kimi Coding — Anthropic-совместимый API от Moonshot AI. OpenClaw имеет встроенную поддержку провайдера `kimi-coding`, поэтому не нужен кастомный `models.providers` блок.

**Что нужно для работы:**

1. API-ключ с [kimi.com/code/console](https://www.kimi.com/code/console) (формат `sk-kimi-...`)
2. В `.env`: `KIMI_API_KEY=sk-kimi-...`
3. В `openclaw.json`: `"agents.defaults.model.primary": "kimi-coding/k2p5"`
4. В `auth-profiles.json`: ключ тоже должен быть `sk-kimi-...` (OpenClaw может использовать его вместо env-переменной)

**Важные нюансы (грабли, на которые мы наступили):**

- `ANTHROPIC_BASE_URL` env-переменная **не работает** в OpenClaw — он игнорирует её. Базовый URL задаётся только через `models.providers` в конфиге или через встроенный провайдер.
- Нельзя хакнуть через `anthropic` провайдер с подменой base URL — OpenClaw требует `models` массив и всё равно может брать ключ из `auth-profiles.json`.
- `auth-profiles.json` (`config/agents/main/agent/auth-profiles.json`) имеет приоритет над env-переменными. Если там старый ключ — он будет использоваться.
- Встроенный провайдер `kimi-coding` — самый простой путь. Он сам знает правильный endpoint (`https://api.kimi.com/coding/`).

**Файлы, которые нужно согласовать:**
```
/opt/openclaw/.env                                    → KIMI_API_KEY=sk-kimi-...
/opt/openclaw/config/openclaw.json                    → model.primary: "kimi-coding/k2p5"
/opt/openclaw/config/agents/main/agent/auth-profiles.json → key: "sk-kimi-..."
```

### Переключение на Anthropic
```bash
# 1. В .env: заменить KIMI_API_KEY на ANTHROPIC_API_KEY=sk-ant-...
# 2. В openclaw.json: поменять model.primary на anthropic/claude-sonnet-4-5
# 3. В auth-profiles.json: обновить key на sk-ant-...
nano /opt/openclaw/config/openclaw.json
cd /opt/openclaw && docker compose down && docker compose up -d openclaw-gateway
```

## Allowlist (кто может писать боту)

В `openclaw.json` → `channels.telegram`:
- `groupAllowFrom`: ["<user-id-1>", "<user-id-2>", ...]
- `allowFrom`: ["<user-id-1>", "<user-id-2>", ...]

Telegram user ID можно узнать через @userinfobot или из логов бота.

## Голосовые сообщения

Транскрипция через OpenAI API (`gpt-4o-mini-transcribe`). Настройка в `openclaw.json`:
```json
"tools": {
  "media": {
    "audio": {
      "enabled": true,
      "language": "ru",
      "models": [
        { "provider": "openai", "model": "gpt-4o-mini-transcribe" }
      ]
    }
  }
}
```
Ключ: `OPENAI_API_KEY` в `.env`.

## Telegram Actions

В `openclaw.json` → `channels.telegram.actions`:
```json
"actions": {
  "reactions": true,
  "sendMessage": true,
  "deleteMessage": true,
  "sticker": true
}
```

## ВкусВилл MCP

Сервер: `https://mcp001.vkusvill.ru/mcp`

Три инструмента:
- `vkusvill_products_search` — поиск (q, page, sort)
- `vkusvill_product_details` — детали + КБЖУ (id)
- `vkusvill_cart_link_create` — ссылка на корзину (products: [{xml_id, q}])

Скрипт-обёртка: `/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh` (подкоманды: search, details, check, cart)

### VV MCP Client (persistent MCP-сессия)

Python-микросервис на хосте, держит одну MCP-сессию и проксирует запросы от бота. Решает проблему 502 Bad Gateway при последовательных вызовах (search → details), которая возникала из-за создания новой MCP-сессии на каждый запрос.

| Параметр | Значение |
|----------|----------|
| Файл | `/opt/openclaw/vv-mcp-client.py` |
| Systemd | `vv-mcp-client.service` |
| Порт | 18791 (bind 0.0.0.0, UFW ограничен Docker-сетями) |
| RAM | ~10-15 MB |
| Зависимости | Python 3 stdlib (без pip) |

API:
- `GET /search?q=...&page=1&sort=popularity`
- `GET /details?id=...`
- `POST /cart` (body: `{"products": [...]}`)
- `GET /health`

```bash
# Управление
systemctl status vv-mcp-client
systemctl restart vv-mcp-client
journalctl -u vv-mcp-client -f

# Тест
curl http://127.0.0.1:18791/health
curl 'http://127.0.0.1:18791/search?q=творог'
curl 'http://127.0.0.1:18791/details?id=27695'
```

Автореконнект: при 502/503/504/timeout переоткрывает MCP-сессию (до 2 ретраев). Сессия обновляется каждые 30 минут (SESSION_TTL=1800).

### Проверка наличия по адресу

Puppeteer-микросервис на хосте (вне Docker). Подробная документация: `VV-CHECKER.md`.

```bash
# Из Docker (бот вызывает через vkusvill.sh check):
curl http://host.docker.internal:18790/check?url=https://vkusvill.ru/goods/xmlid/98052

# С сервера напрямую:
curl http://127.0.0.1:18790/check?url=https://vkusvill.ru/goods/xmlid/98052
```

### Тест всех подкоманд
```bash
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh search "молоко"
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh details 27695
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh check 98052
```
