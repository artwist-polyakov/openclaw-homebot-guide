# OpenClaw Telegram Bot — Руководство по администрированию

Практический гайд по настройке и эксплуатации семейного Telegram-бота на базе [OpenClaw](https://github.com/openclaw/openclaw). Включает интеграцию с ВкусВилл (поиск, КБЖУ, проверка наличия, корзина), голосовые сообщения, heartbeat, веб-поиск через Perplexity и Puppeteer-микросервис для проверки наличия товаров.

## Сервер

- **ОС:** Ubuntu 22.04, 2GB RAM, 30GB диск
- **Docker:** 24.0.7 + Compose 2.21.0

## Структура на сервере

```
/opt/openclaw/
├── docker-compose.yml          # Docker-конфиг (порты, env, образ)
├── update.sh                   # Скрипт автообновления
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
│       └── vkusvill.sh         # Скрипт-обёртка MCP API ВкусВилл
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
# Доступные: kimi-coding/k2p5, anthropic/claude-opus-4-6, anthropic/claude-sonnet-4-5, anthropic/claude-haiku-4-5
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

- **DM Policy:** allowlist (только пользователи из списка)
- **Группы:** отвечает только на @упоминания и реплаи

### Одобрить нового пользователя
```bash
docker exec openclaw-gateway node dist/index.js pairing approve telegram <КОД>
```

### Добавить бота в группу
1. Добавить бота в группу
2. Сделать админом (чтобы видел все сообщения) или отключить Privacy Mode через @BotFather → /setprivacy → Disable
3. Тегать через @botname для вызова

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

Gateway token хранится в `openclaw.json` → `gateway.token`.

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

### Изоляция DM-сессий

Настройка `session.dmScope: "per-channel-peer"` изолирует контекст личных сообщений по связке "канал + отправитель". Без этого при нескольких пользователях возможна утечка контекста между людьми (cross-user leakage) — модель может "подтянуть" куски чужой переписки.

```json
"session": {
  "dmScope": "per-channel-peer"
}
```

## Автоматизация (cron)

| Задача | Расписание (МСК) | Команда |
|--------|-----------------|---------|
| Docker prune | Вс 4:00 | `docker system prune -af --filter "until=168h"` |
| Обновление OpenClaw | Пн 5:00 | `/opt/openclaw/update.sh` |
| VV-checker keepalive | Ежедневно 10:00 | `curl -s http://127.0.0.1:18790/check?url=...` |

Логи: `/var/log/docker-prune.log`, `/var/log/openclaw-update.log`

Пример crontab: [`openclaw/crontab.example`](openclaw/crontab.example)

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
- `auth-profiles.json` имеет приоритет над env-переменными. Если там старый ключ — он будет использоваться.
- Встроенный провайдер `kimi-coding` — самый простой путь. Он сам знает правильный endpoint.

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
```json
"allowFrom": ["<TELEGRAM_USER_ID_1>", "<TELEGRAM_USER_ID_2>"],
"groupAllowFrom": ["<TELEGRAM_USER_ID_1>", "<TELEGRAM_USER_ID_2>"]
```

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

Четыре команды через единый скрипт `vkusvill.sh`:
- `search` — поиск (q, page, sort)
- `details` — детали + КБЖУ (id)
- `check` — проверка наличия по адресу доставки (id или URL)
- `cart` — ссылка на корзину (products: [{xml_id, q}])

### Проверка наличия по адресу

Puppeteer-микросервис на хосте (вне Docker). Подробная документация: [`vv-checker/README.md`](vv-checker/README.md).

```bash
# Из Docker (бот вызывает через vkusvill.sh check):
curl http://host.docker.internal:18790/check?url=https://vkusvill.ru/goods/xmlid/98052

# С сервера напрямую:
curl http://127.0.0.1:18790/check?url=https://vkusvill.ru/goods/xmlid/98052
```

Тест:
```bash
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh search "молоко"
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh details 27695
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh check 98052
```
