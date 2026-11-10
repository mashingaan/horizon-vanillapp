# Horizon Vanilla++ для Windows 11 x64

Состояние M1 на 10 ноября 2026 года. Установщик проверяет архивы и разворачивает ресурсы в изолированном экземпляре официального лаунчера Horizon. Клиент с Tectonic, первый игровой запуск и результаты на RTX 2060 еще требуют проверки.

## Развертывание пакетов

Понадобятся PowerShell 7.4 или новее, свободное место на диске и законная копия Minecraft Java Edition. Скачайте файл `Patrix_26.3_32x_basic.zip` из выпуска [Patrix 32x Basic 93](https://modrinth.com/resourcepack/patrix-32x/version/V9k0Ak3w). Остальные архивы скрипт скачает с GitHub и Modrinth. Patrix хранится в каталоге экземпляра по вашему выбору.

Из корня этого репозитория выполните следующую команду. Замените путь к архиву на свой. Укажите новый пустой каталог для `-Root`.

```powershell
./Install.ps1 -Root 'E:\HorizonVanillaPP' -Action InstallPacks -PatrixZip 'E:\Downloads\Patrix_26.3_32x_basic.zip'
```

`InstallPacks` включает Patrix и применяет Balanced по умолчанию. Для скачивания и проверки архивов без запуска лаунчера укажите `-Action Stage`. Папки `launcher-data` и `game-data` хранят отдельные данные лаунчера и игры. Внутри экземпляра находятся `resourcepacks`, `shaderpacks`, настройки и сохранения. Архив Tectonic хранится в `downloads` для проверки перед сборкой.

## Подключение клиента с Tectonic

1. Запустите `Verify pack` в GitHub Actions со входом `windows_client=true` на доступном бесплатном стандартном runner. После успешного прогона распакуйте артефакт `horizon-vanillapp-windows-x64` в отдельный каталог. Workflow сверяет исходники и хеш Tectonic, применяет миксины и собирает клиент.
2. Проверьте репозиторий, ревизию и происхождение прогона перед использованием `-TrustHostedClient`. Скрипт сверяет SHA-256 клиента и содержимое `pack.lock.json` артефакта. Он устанавливает основу из официального ZIP `nightly-2026-11-04` с закрепленным SHA-256, затем импортирует клиент и назначает его отдельному экземпляру. Если нужен только официальный Nightly, используйте `-Action InstallBase`. У этого Nightly совпадают `research-lock.json`, дерево `horizon-prepare/src` и версии его выходных данных с закрепленной ревизией клиента Tectonic. Игровая проверка этой пары еще предстоит. [Выпуск Nightly](https://github.com/horizon-rust/horizon/releases/tag/nightly-2026-11-04) · [Импорт клиента](https://github.com/horizon-rust/horizon/blob/8dbbde43501924d16497d251e6e9d08f812eafcd/launcher/src/build_import.rs)

```powershell
./Install.ps1 -Root 'E:\HorizonVanillaPP' -Action ImportClient -ClientArtifact 'E:\UserTemp\horizon-vanillapp-windows-x64' -TrustHostedClient
./Install.ps1 -Root 'E:\HorizonVanillaPP' -Action OpenLauncher
```

3. Войдите в аккаунт Microsoft. Выполните Prepare из законной копии Minecraft 26.3 и запустите игру. В Options → Mods проверьте, что Tectonic-Horizon включен, затем создайте новый тестовый мир. В выделенном экземпляре конфигурация Tectonic хранится в `config/tectonic-horizon.json`. Сохраняйте одинаковые настройки генерации при повторном открытии мира.

## Профили, обновление и миры

| Профиль | Шейдер на этапе M1 | Обычная дальность / LOD, чанки |
| --- | --- | --- |
| Performance | Wisdom Lite | 8 / 64 |
| Balanced | Wisdom | 12 / 128 |
| Cinematic | Photon, экспериментальный | 20 / 256 |

Закройте игру перед переключением. Профиль меняет выбранный шейдер, дальность, детализацию LOD, дальность симуляции, частицы и облака. Окончательный выбор шейдера для Balanced зависит от сравнения на RTX 2060.

```powershell
./Install.ps1 -Root 'E:\HorizonVanillaPP' -Action Profile -Profile Performance
./Install.ps1 -Root 'E:\HorizonVanillaPP' -Action Backup -World 'Horizon Test'
```

Команда Backup вызывает резервное копирование Horizon для указанного мира, проверяет наличие `level.dat` и выводит путь к ZIP и его SHA-256. Чтобы восстановить мир, сначала распакуйте ZIP в отдельный пустой каталог, затем перенесите сохранение в новый экземпляр с тем же клиентом, набором модов и настройками генерации. Если в экземпляре уже есть сохранения, установщик разрешает повторный импорт только клиента с прежним SHA-256. Для новой ревизии используйте другой `-Root` и новый тестовый мир. Перед переносом мира снимите резервную копию и проверьте, что восстановленная копия открывается.

## Проверка

- [Аудит M0 и матрица модов](docs/M0.md)
- `tests/Test-Stage.ps1` проверяет закрепленные метаданные и отказ при изменении байтов кешированного файла.
- `Verify pack` запускает проверку установщика. Опциональные задачи отдельно проверяют трансляцию Photon и собирают Windows-клиент с Tectonic. Прогон трансляции не проверяет отрисовку на GPU.
- Для приемки проверьте Patrix, переход от ближних чанков к LOD, повторное открытие мира и восстановление копии. Сравните Photon, Wisdom и остальные кандидаты на одном тестовом маршруте через горы, лес, воду и дождь.

После подготовки и входа в выделенном лаунчере можно запустить встроенный тест клиента. Сначала примените профиль и установите разрешение 1920×1080. Запускайте тест в отдельном экземпляре без пользовательского мира с именем `horizon-benchmark`. Horizon использует это имя для своего тестового сохранения и заменяет его при следующем прогоне.

```powershell
$root = 'E:\HorizonVanillaPP'
$env:HORIZON_LAUNCHER_HOME = Join-Path $root 'launcher-data'
$env:HORIZON_HOME = Join-Path $root 'game-data'
$launcher = Join-Path $root 'tools\horizon-launcher-0.2.58.exe'
$instance = (& $launcher instance list --json | ConvertFrom-Json) | Where-Object name -eq 'Horizon Vanilla++ M1'
$env:TECTONIC_HORIZON_CONFIG = Join-Path $instance.home 'config/tectonic-horizon.json'
& $launcher play --instance $instance.id --arg=--benchmark --arg=standard | Out-Host
```

Сделайте три прогона каждого профиля. Сохраните JSON из `benchmarks/` экземпляра и сверяйте разрешение, GPU, активный шейдер, дальность и версию клиента в отчетах. Для каждой сцены сравните `avg_fps`, `low_1pct_fps`, `p99_ms` и число кадров длиннее 50 мс. Целевые 60 FPS и 1% low не ниже 40 относятся к Balanced. При наличии запишите `memory.gpu_mb` и пиковый RSS. Для проверки пика VRAM дополнительно снимите максимальное показание выделенной памяти GPU за прогон, указав инструмент и область измерения. [Методика Horizon](https://github.com/horizon-rust/horizon/blob/8dbbde43501924d16497d251e6e9d08f812eafcd/docs/benchmark.md) · [Поля отчета](https://github.com/horizon-rust/horizon/blob/8dbbde43501924d16497d251e6e9d08f812eafcd/docs/benchmark-report.md)
