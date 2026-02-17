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

Это изолирует DM-контекст по связке "канал + отправитель". Каждый пользователь получает отдельную сессию, без доступа к чужим сообщениям.

**Статус:** Настроено в нашем `openclaw.json`.

---

## Bootstrap-файлы не обновляются без сброса сессии

**Проблема:** Обновил AGENTS.md, SOUL.md или HEARTBEAT.md — а бот ведёт себя по-старому. Bootstrap-файлы читаются **только** при старте сессии. Если сессия уже активна — изменения не подхватываются.

**Решение:** Настроить ежедневный сброс:

```json
{
  "session": {
    "reset": {
      "mode": "daily",
      "atHour": 4
    }
  }
}
```

В 4:00 МСК все сессии сбрасываются. При следующем сообщении бот перечитает все файлы.

**Ручной сброс:** Отправить `/new` в чат или `docker restart openclaw-gateway`.

**Статус:** Настроено — daily reset в 4:00 МСК.

---

## auth-profiles.json перебивает env-переменные

**Проблема:** При смене LLM-провайдера (например, с Anthropic на Kimi Coding) можно обновить `.env`, но забыть про `auth-profiles.json`. OpenClaw берёт ключ из `auth-profiles.json` с более высоким приоритетом — и отправляет старый ключ новому провайдеру, получая 401.

**Решение:** Очистить `auth-profiles.json` до `{"profiles":[]}` и использовать только `.env` для ключей. Тогда при смене провайдера обновлять только два файла:
- `/opt/openclaw/.env` (ключ)
- `/opt/openclaw/config/openclaw.json` (model.primary)

---

## ANTHROPIC_BASE_URL не работает в OpenClaw

**Проблема:** В Claude Code можно задать `ANTHROPIC_BASE_URL` для перенаправления запросов на совместимый API (например, Kimi Coding). В OpenClaw эта переменная **игнорируется**. Запросы всё равно уходят на `api.anthropic.com`.

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

Kimi Coding (`kimi.com/code/console`) — Anthropic-совместимый API. В OpenClaw есть встроенный провайдер `kimi-coding`.

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

**Проблема:** По умолчанию Telegram-боты не видят сообщения в группах (Privacy Mode включён). Бот получает только команды (начинающиеся с `/`) и сообщения, где его тегнули или ответили реплаем.

**Решение:** Отключить Privacy Mode через @BotFather:
1. Открыть @BotFather
2. `/mybots` → выбрать бота → Bot Settings → Group Privacy → Turn off
3. Удалить и заново добавить бота в группу (иначе изменение не применится)

---

## Docker-логи пустые после старта

**Проблема:** После `docker compose up -d` логи через `docker logs` пустые первые ~30-90 секунд. OpenClaw тратит это время на инициализацию (компиляция, загрузка моделей).

**Решение:** Просто подождать. На VPS с 2GB RAM запуск занимает ~30-60 секунд. Проверить готовность:
```bash
docker logs openclaw-gateway --tail 5
# Ждём строку: [telegram] starting provider (@botname)
```

---

## Perplexity как провайдер web_search

**Проблема:** По умолчанию OpenClaw использует Brave Search для `web_search`. Можно подключить Perplexity, но есть баг — OpenClaw отправляет модель как `perplexity/sonar-pro`, а Perplexity API ожидает `sonar-pro` без префикса.

**Решение:**

1. Убрать `web_search` и `web_fetch` из `tools.deny`, добавить в `tools.allow`
2. Настроить провайдер и переопределить модель:

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

3. Добавить `PERPLEXITY_API_KEY=pplx-...` в `.env`

**Ключевой момент:** без `"perplexity": {"model": "sonar-pro"}` будет ошибка `Invalid model 'perplexity/sonar-pro'`. Настройка `tools.web.search.perplexity.model` скрытая — нет в документации, нашли в исходниках.

**Доступные модели Perplexity:** `sonar` (лёгкий), `sonar-pro` (глубокий), `sonar-reasoning`, `sonar-reasoning-pro`, `sonar-deep-research`.

---

## Часовой пояс контейнера

**Проблема:** Docker-контейнер по умолчанию в UTC. Бот думает что сейчас 20:45, хотя по Москве 23:45. Это влияет на ответы про время доставки, расписание и т.д.

**Решение:** Добавить `TZ=Europe/Moscow` в `.env`. Docker-compose подтягивает через `env_file`.

Проверить: `docker exec openclaw-gateway date` — должно показать MSK.

---

## Telegram превращает имена файлов в ссылки

**Проблема:** Telegram автоматически парсит текст вроде `HEARTBEAT.md` или `AGENTS.md` как кликабельные ссылки (домен `.md`). Выглядит как баг в сообщениях бота.

**Решение:** В `AGENTS.md` добавить правило для бота:
```
- Всегда оборачивай имена файлов в обратные кавычки: `HEARTBEAT.md`, `TOOLS.md`, `AGENTS.md`
```

Telegram не парсит ссылки внутри inline-code блоков (обратных кавычек).

**Статус:** Правило добавлено в AGENTS.md на сервере.

---

## Веб-админка не принимает токен через SSH-туннель

**Проблема:** Control UI показывает `gateway token missing` и не даёт ввести токен. Save неактивен. Даже с правильным токеном в URL — не работает. Причина: Control UI требует device-аутентификацию, а через SSH-туннель (localhost) её нет.

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

Это разрешает авторизацию только по токену без device identity. Безопасно, потому что админка доступна только через SSH-туннель (loopback).

Есть ещё `dangerouslyDisableDeviceAuth` — полностью отключает проверку устройства. Использовать только как break-glass.

**Доступ через Termius:**
1. Port Forwarding → Local Forwarding
2. Local: `127.0.0.1:18789`, Intermediate host: сервер, Destination: `127.0.0.1:18789`
3. Открыть `http://localhost:18789`
4. Ввести gateway token

---

## Голосовые сообщения (Whisper / audio transcription)

**Проблема:** Бот не транскрибирует голосовые сообщения в Telegram. Отвечает «напиши текстом».

**Причины и решение:**

1. **Нет конфига `tools.media.audio`** — нужно включить встроенный пайплайн транскрипции:

```json
{
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
}
```

2. **`OPENAI_API_KEY` не виден внутри контейнера** — ключ добавлен в `.env`, но контейнер перезапущен через `docker restart`. Команда `restart` **не перечитывает `.env`** — нужен `docker compose down && docker compose up -d`.

3. **Скилл `openai-whisper-api` — не нужен.** Это отдельный скилл, который пытается установить whisper через `brew` (падает с `brew not installed` внутри Docker). Встроенный пайплайн `tools.media.audio` работает через OpenAI API напрямую — он лучше. Не надо дублировать ключ в `skills.entries`.

**Правильная модель:** `gpt-4o-mini-transcribe` (не `whisper-1`, не `whisper-large-v3-turbo`).

**Файлы:**
```
/opt/openclaw/.env                    → OPENAI_API_KEY=sk-proj-...
/opt/openclaw/config/openclaw.json    → tools.media.audio (конфиг выше)
```

**Статус:** Настроено. Скилл `openai-whisper-api` удалён из конфига.

---

## `docker restart` не перечитывает `.env`

**Проблема:** После добавления новой переменной в `.env` (например, `OPENAI_API_KEY`) и `docker restart openclaw-gateway` — переменная не видна внутри контейнера. `printenv` показывает пустоту.

**Причина:** `docker restart` перезапускает процесс с **теми же** env-переменными, которые были при создании контейнера. Новые переменные из `.env` не подхватываются.

**Решение:** Пересоздать контейнер:
```bash
cd /opt/openclaw && docker compose down && docker compose up -d openclaw-gateway
```

**Когда какой restart:**
- `docker restart` — безопасно для изменений в конфигах (openclaw.json, AGENTS.md) и кода
- `docker compose down && up` — обязательно при изменении `.env` или `docker-compose.yml`

---

## Heartbeat — автоматическое пробуждение бота

**Проблема:** Бот говорит, что реагирует только на сообщения и дёргает heartbeat только после пробуждения. Без конфига `agents.defaults.heartbeat` подсистема стартует, но периодические проверки не запускаются.

**Решение:** Настроить heartbeat в `openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "heartbeat": {
        "every": "30m",
        "target": "last",
        "activeHours": {
          "start": "08:00",
          "end": "23:00",
          "timezone": "Europe/Moscow"
        }
      }
    }
  }
}
```

**Параметры:**
- `every` — интервал (`"30m"`, `"1h"`, `"6h"`, `"0m"` для отключения)
- `target` — куда слать: `"last"` (последний активный канал), `"none"`, или ID канала
- `activeHours` — временное окно (вне его heartbeat пропускается)
- `model` — можно задать отдельную модель для heartbeat
- `prompt` — кастомный промпт (по умолчанию читает `HEARTBEAT.md`)

**Протокол ответа:** Бот отвечает `HEARTBEAT_OK` если всё в порядке (сообщение не доставляется). Если есть алерт — пишет текст без `HEARTBEAT_OK` (доставляется в чат).

**Heartbeat vs Cron:**
- Heartbeat — периодический (каждые N минут), нельзя задать точное время
- Для точного расписания (например, «каждый день в 9:00») — использовать Cron Jobs OpenClaw

**Hot-reload:** Настройка применяется без рестарта контейнера.

**Нюанс `target`:**
- `"last"` — последний активный чат (группа или DM — зависит от контекста). Самый гибкий вариант для семейного бота.
- `"telegram"` + `"to": "6488767"` — всегда в DM конкретному пользователю
- `"telegram"` + `"to": "-100XXXXXXXXXX"` — всегда в конкретную группу

**Важно:** `target` управляет только **алертами**. Если бот отвечает `HEARTBEAT_OK` — ничего никуда не доставляется (нет спама). Алерт уходит только когда бот решил что-то сказать.

С `actions.sendMessage: true` бот может во время heartbeat-тика сам решить кому и куда написать, независимо от `target`.

**Статус:** Настроено — каждые 15 мин, 08:00–23:00 МСК, target: last.

---

## fail2ban — нужен ли?

**Ответ:** Да, обязательно.

**Почему:** Сервер (VDSina) имеет SSH-порт открытый в интернет. При установке fail2ban сразу забанил 5 IP и обнаружил 46 неудачных попыток входа — SSH атакуют постоянно.

**Что защищает:**
- SSH brute-force (главная угроза для VPS)
- Бот-сети, которые сканируют интернет на открытые SSH-порты 24/7

**Что НЕ нужно защищать (уже защищено):**
- Gateway (порт 18789) — слушает только `127.0.0.1` (loopback), недоступен извне
- Web-админка — только через SSH-туннель

**Настроено:** `/etc/fail2ban/jail.local`:
```ini
[sshd]
enabled = true
maxretry = 3
bantime = 3600
findtime = 600
```
Бан на 1 час после 3 неудачных попыток за 10 минут.

**Полезные команды:**
```bash
sudo fail2ban-client status sshd     # посмотреть забаненных
sudo fail2ban-client unban <IP>      # разбанить IP
```

**Статус:** Установлен и работает.

---

## UFW — обязательно включить

**Проблема:** По умолчанию UFW отключён на Ubuntu VPS. Все порты открыты в интернет. Если сервис слушает на `0.0.0.0` (например, vv-checker для Docker bridge) — он доступен извне.

**Решение:**
```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
echo 'y' | ufw enable
```

**Что разрешено:** только SSH (22/tcp).

**Дополнительные правила для Docker:**
```bash
ufw allow from 172.17.0.0/16 to any port 18790 comment 'vv-checker from Docker'
ufw allow from 172.18.0.0/16 to any port 18790 comment 'vv-checker from Docker compose'
```

**VV MCP Client (порт 18791)** — аналогичные правила:
```bash
ufw allow from 172.17.0.0/16 to any port 18791 comment 'vv-mcp-client from Docker'
ufw allow from 172.18.0.0/16 to any port 18791 comment 'vv-mcp-client from Docker compose'
ufw allow from 172.23.0.0/16 to any port 18791 comment 'vv-mcp-client from Docker openclaw'
```

**Важно:** docker-compose создаёт свою сеть (`172.18.0.0/16`), а не использует default bridge (`172.17.0.0/16`). Нужны оба правила.

**Что НЕ нужно открывать:**
- 18789 (OpenClaw gateway) — биндится на `127.0.0.1`, UFW не нужен
- 18790 из интернета — закрыт UFW, открыт только для Docker-сетей
- 9222 (Chrome DevTools) — закрыт UFW, доступен через SSH tunnel

**Статус:** Установлен и работает.

---

## VkusVill: проверка наличия не работает через curl

**Проблема:** curl с полным набором кук (11 штук) + все заголовки браузера не получает блок `#product-quantity-block`. Сервер ВкусВилл проверяет TLS fingerprint или глубокую серверную валидацию — только настоящий Chrome проходит.

**Решение:** Puppeteer-микросервис на хосте (вне Docker). Подробности: `VV-CHECKER.md`.

**Ключевые грабли:**
- `schema.org InStock` всегда присутствует — нельзя использовать как индикатор наличия
- Куки `_vv_card`, `UF_USER_AUTH`, `adrdel` без валидной `__Host-PHPSESSID` бесполезны
- Адрес доставки привязан к PHP-сессии на сервере, а не к кукам клиента
- Для настройки адреса нужно один раз зайти в headless Chrome через `chrome://inspect` (SSH port forward 9222)

**Статус:** Настроено, работает. Документация: `VV-CHECKER.md`.

---

## `fetch failed` в OpenClaw — известный баг

**Проблема:** В логах `TypeError: fetch failed` (Non-fatal). Появляется периодически.

**Причина:** Известный баг OpenClaw (GitHub issues #7553, #5199, #4425 и другие). Node.js `fetch()` (undici) не обёрнут в try/catch. Временные сетевые проблемы к внешним API (Telegram, Perplexity, Kimi) вызывают unhandled promise rejection.

**Влияние:** Non-fatal — бот продолжает работать. Логи засоряет, но не крашит.

**Связанная проблема:** Issue #2935 — heartbeat перестаёт тикать после context compression. Workaround: периодический рестарт контейнера.

---

## Контекстный бюджет bootstrap-файлов

**Проблема:** Все `.md` файлы в workspace грузятся в каждое сообщение. Если суммарно превышают `bootstrapMaxChars` (дефолт 20,000) — OpenClaw обрезает по правилу 70/20/10, инструкции молча теряются.

**Текущие размеры (после оптимизации):**

| Файл | Main | FamilyOffice | Лимит BP |
|------|------|--------------|----------|
| AGENTS.md | 2,439 | 728 | < 2,000 |
| SOUL.md | 2,258 | 2,421 | < 3,000 |
| HEARTBEAT.md | 1,939 | 4,109 | < 4,000 |
| USER.md | 477 | 1,129 | < 1,500 |
| TOOLS.md | 359 | 860 | < 1,000 |
| IDENTITY.md | 36 | 636 | < 1,000 |
| **Итого** | **~7.6KB** | **~10KB** | **< 15KB** |

**Ключевые правила:**
- Детальные инструкции по скиллам → в SKILL.md (грузится только при вызове)
- Шаблонные примеры → удалять (камеры, SSH, TTS)
- Протухшие задачи → бот чистит сам (секция "Самоочистка" в HEARTBEAT.md)
- Проверять: `wc -c /opt/openclaw/workspace/*.md`

---

## VkusVill 502 при последовательных MCP-запросах

**Проблема:** Бот жалуется, что API ВкусВилл не возвращает КБЖУ. При этом поиск работает, а `details` падает с 502 Bad Gateway.

**Причина:** `vkusvill.sh` создавал новую MCP-сессию на каждый вызов (initialize → tools/call). При последовательных запросах (search → details) второй `initialize` приходит, пока сервер ещё обрабатывает первую сессию — получаем 502. По отдельности каждый запрос работает.

**Решение:** VV MCP Client (`vv-mcp-client.py`) — Python-микросервис на хосте, который держит одну MCP-сессию и проксирует все запросы через неё. `vkusvill.sh` вместо прямых MCP-вызовов делает `curl http://host.docker.internal:18791/...`.

**Файлы:**
```
/opt/openclaw/vv-mcp-client.py            # Сервис
/etc/systemd/system/vv-mcp-client.service # Systemd unit
/opt/openclaw/workspace/skills/vkusvill/vkusvill.sh  # Обновлён: curl вместо MCP
```

**Управление:**
```bash
systemctl status vv-mcp-client
systemctl restart vv-mcp-client
journalctl -u vv-mcp-client -f
```

**Статус:** Настроено, работает. КБЖУ стабильно возвращается.

---

## Sandbox mode внутри Docker

**Проблема:** OpenClaw пытается запустить Docker-in-Docker для песочницы. Внутри контейнера это невозможно — ошибка `spawn docker EACCES`.

**Решение:** Отключить песочницу (контейнер сам по себе является изоляцией):
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
