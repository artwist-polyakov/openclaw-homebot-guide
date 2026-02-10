# OpenClaw — подводные камни и советы

## Изоляция DM-сессий (cross-user leakage)

**Проблема:** По умолчанию OpenClaw считает, что DM — личный помощник для одного человека. Все личные сообщения попадают в один общий контекст ("main"). Если добавить несколько пользователей — они косвенно влияют на общий контекст, и модель может "подтянуть" куски чужой переписки.

**Решение:** Включить `per-channel-peer` режим:

```json
{
  "session": {
    "dmScope": "per-channel-peer"
  }
}
```

---

## auth-profiles.json перебивает env-переменные

**Проблема:** При смене LLM-провайдера можно обновить `.env`, но забыть про `auth-profiles.json`. OpenClaw берёт ключ из `auth-profiles.json` с более высоким приоритетом — и отправляет старый ключ новому провайдеру, получая 401.

**Решение:** Очистить `auth-profiles.json` до `{"profiles":[]}` и использовать только `.env` для ключей.

---

## ANTHROPIC_BASE_URL не работает в OpenClaw

**Проблема:** В Claude Code можно задать `ANTHROPIC_BASE_URL` для перенаправления запросов на совместимый API. В OpenClaw эта переменная **игнорируется**.

**Решение:** Использовать встроенные провайдеры OpenClaw (например, `kimi-coding`) или задавать `baseUrl` через `models.providers` в конфиге:

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "my-provider": {
        "baseUrl": "https://custom-api.example.com/v1",
        "api": "anthropic-messages",
        "models": [{"id": "model-id", "name": "Model Name"}]
      }
    }
  }
}
```

---

## Kimi Coding — правильная настройка

**Правильно:**
```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "kimi-coding/k2p5" }
    }
  }
}
```
Env: `KIMI_API_KEY=sk-kimi-...`

**Неправильно:**
- Использовать `moonshot/kimi-k2.5` с `baseUrl: api.moonshot.ai` — ключ `sk-kimi-` не подходит к этому API
- Использовать `anthropic/claude-sonnet-4-5` с `ANTHROPIC_BASE_URL` — OpenClaw игнорирует эту переменную
- Забыть обновить `auth-profiles.json` — старый ключ перебьёт `.env`

---

## Telegram Privacy Mode

**Проблема:** По умолчанию Telegram-боты не видят сообщения в группах.

**Решение:** Отключить Privacy Mode через @BotFather:
1. `/mybots` → выбрать бота → Bot Settings → Group Privacy → Turn off
2. Удалить и заново добавить бота в группу

---

## Docker-логи пустые после старта

OpenClaw тратит ~30-60 секунд на инициализацию. Проверить готовность:
```bash
docker logs openclaw-gateway --tail 5
# Ждём строку: [telegram] starting provider (@botname)
```

---

## Perplexity как провайдер web_search

**Проблема:** OpenClaw отправляет модель как `perplexity/sonar-pro`, а Perplexity API ожидает `sonar-pro` без префикса.

**Решение:**

```json
{
  "tools": {
    "allow": ["read", "exec", "web_search", "web_fetch"],
    "deny": ["browser", "write", "edit", "process", "apply_patch"],
    "web": {
      "search": {
        "provider": "perplexity",
        "apiKey": "${PERPLEXITY_API_KEY}",
        "maxResults": 5,
        "timeoutSeconds": 30,
        "perplexity": {
          "model": "sonar-pro"
        }
      },
      "fetch": {
        "enabled": true
      }
    }
  }
}
```

**Ключевой момент:** без `"perplexity": {"model": "sonar-pro"}` будет ошибка `Invalid model 'perplexity/sonar-pro'`. Настройка скрытая — нашли в исходниках.

---

## Часовой пояс контейнера

Добавить `TZ=Europe/Moscow` в `.env`. Проверить: `docker exec openclaw-gateway date`.

---

## Telegram превращает имена файлов в ссылки

Telegram парсит `HEARTBEAT.md` как ссылку (домен `.md`). В `AGENTS.md` добавить правило:
```
- Всегда оборачивай имена файлов в обратные кавычки: `HEARTBEAT.md`, `TOOLS.md`
```

---

## Веб-админка не принимает токен через SSH-туннель

**Решение:** Добавить в `openclaw.json`:

```json
{
  "gateway": {
    "controlUi": {
      "allowInsecureAuth": true
    }
  }
}
```

---

## Голосовые сообщения (Whisper / audio transcription)

Нужно включить `tools.media.audio` + `OPENAI_API_KEY` в `.env` + пересоздать контейнер (`docker compose down && up`, не `restart`).

**Правильная модель:** `gpt-4o-mini-transcribe` (не `whisper-1`).

**Скилл `openai-whisper-api` не нужен.** Встроенный пайплайн `tools.media.audio` работает через OpenAI API напрямую.

---

## `docker restart` не перечитывает `.env`

- `docker restart` — безопасно для изменений в конфигах (openclaw.json, AGENTS.md)
- `docker compose down && up` — обязательно при изменении `.env` или `docker-compose.yml`

---

## Heartbeat — `target: "last"` отправляет в ЛС, а не в группу

**Проблема:** `target: "last"` берёт `deliveryContext` из главной сессии агента. Если первое взаимодействие было в ЛС — heartbeat навсегда застревает в ЛС и самоподдерживается (heartbeat создаёт сессию → сессия указывает на ЛС → следующий heartbeat идёт туда же).

**Решение:** Для гарантированной доставки в группу используйте `target: "telegram"` + `to` на уровне конкретного агента:

```json
{
  "agents": {
    "list": [
      {
        "id": "main",
        "name": "FoodHelper",
        "heartbeat": {
          "every": "15m",
          "target": "telegram",
          "to": "-100XXXXXXXXXX",
          "activeHours": {
            "start": "08:00",
            "end": "23:00",
            "timezone": "Europe/Moscow"
          }
        }
      }
    ]
  }
}
```

| Значение target | Куда шлёт |
|-----------------|-----------|
| `"last"` | deliveryContext главной сессии (часто ЛС!) |
| `"telegram"` + `to` | Конкретный Telegram-чат (рекомендуется) |
| `"none"` | Никуда — heartbeat работает, но не отправляет |

**Известная проблема:** Issue #2935 — heartbeat перестаёт тикать после context compression. Workaround: периодический рестарт контейнера.

---

## fail2ban — нужен ли?

**Да.** SSH атакуют постоянно. Настройка:
```ini
[sshd]
enabled = true
maxretry = 3
bantime = 3600
findtime = 600
```

---

## UFW — обязательно включить

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
echo 'y' | ufw enable
```

**Дополнительные правила для Docker:**
```bash
ufw allow from 172.17.0.0/16 to any port 18790 comment 'vv-checker from Docker'
ufw allow from 172.18.0.0/16 to any port 18790 comment 'vv-checker from Docker compose'
```

**Важно:** docker-compose создаёт свою сеть (`172.18.0.0/16`), а не default bridge (`172.17.0.0/16`). Нужны оба правила.

---

## VkusVill: проверка наличия не работает через curl

curl с полным набором кук не получает блок `#product-quantity-block`. Сервер проверяет TLS fingerprint — только настоящий Chrome проходит.

**Решение:** Puppeteer-микросервис. Подробности: [`vv-checker/README.md`](vv-checker/README.md).

---

## `fetch failed` в OpenClaw — известный баг

Известный баг (GitHub issues #7553, #5199, #4425). Non-fatal — бот продолжает работать.

---

## Мульти-агенты: chown обязателен

**Проблема:** При создании workspace и agent dir для нового агента файлы принадлежат root. Контейнер OpenClaw бежит от uid=1000 (node) и получает `EACCES: permission denied`.

**Решение:** После создания директорий:
```bash
chown -R 1000:1000 /opt/openclaw/config/workspace-<name>
chown -R 1000:1000 /opt/openclaw/config/agents/<name>
```

---

## Мульти-агенты: bindings для маршрутизации

**Проблема:** Добавили нового агента, но все сообщения по-прежнему идут к default-агенту.

**Решение:** Добавить binding в `openclaw.json`:
```json
"bindings": [
  {
    "agentId": "familyoffice",
    "match": {
      "channel": "telegram",
      "peer": { "kind": "group", "id": "-100XXXXXXXXXX" }
    }
  }
]
```

Всё что не попало в bindings идёт к агенту с `"default": true`.

---

## Sandbox mode внутри Docker

Отключить песочницу (контейнер сам по себе является изоляцией):
```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "mode": "off"
      }
    }
  }
}
```
