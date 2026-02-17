# SashaDashaHomeBot — Администрирование

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
│   ├── credentials/            # Telegram allowlists, pairing
│   └── agents/main/sessions/   # Сессии (история чатов)
├── workspace/
│   ├── AGENTS.md               # Персона бота (тон, поведение, правила)
│   ├── IDENTITY.md             # Имя и эмодзи
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

- **Бот:** @sashadashahomebot
- **DM Policy:** allowlist (только пользователи из списка)
- **Группы:** отвечает только на @упоминания и реплаи

### Одобрить нового пользователя
```bash
docker exec openclaw-gateway node dist/index.js pairing approve telegram <КОД>
```

### Добавить бота в группу
1. Добавить @sashadashahomebot в группу
2. Сделать админом (чтобы видел все сообщения) или отключить Privacy Mode через @BotFather → /setprivacy → Disable
3. Тегать через @sashadashahomebot для вызова

### Ограничить конкретной группой
В `openclaw.json` заменить `"*"` на ID группы:
```json
"groups": {
  "-1001234567890": {
    "requireMention": true
  }
}
```

## Веб-админка

Доступна через SSH-туннель:
```bash
ssh -L 18789:127.0.0.1:18789 <user>@<IP-сервера>
```
Или через Port Forwarding в Termius (Local 18789 → Remote 127.0.0.1:18789).

Открыть: http://localhost:18789

Gateway token:
```
5900ad829ff0c05e31954e9e32ca82bc147412fb5d2f49fd054de66c80f0629e
```

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
| Sandbox | off (внутри Docker) | openclaw.json |
| mDNS | off | openclaw.json |
| Модель | kimi-coding/k2p5 | openclaw.json |

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
- `groupAllowFrom`: ["6488767", "117054118", "108642608"]
- `allowFrom`: ["6488767", "117054118", "108642608"]

Участники: Саша (6488767), Ангелина (117054118), Даша (108642608).

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
