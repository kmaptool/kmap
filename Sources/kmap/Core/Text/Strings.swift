import Foundation

/// The interface's translations, as compiled-in Swift rather than a resource bundle, so
/// that kmap remains a single file.
///
/// English has no table: a key is its own English text. A new language needs a `Lang`
/// case, a rule in `L10n.plural(_:in:)` and a table here.
enum Strings {
    /// Returns the translation of `key` in `language`, or nil where English stands.
    static func text(_ key: String, in language: Lang) -> String? {
        switch language {
        case .en: return nil
        case .ru: return russian[key]
        }
    }

    /// Returns the plural forms of `key`, keyed by CLDR category. English is present
    /// here because a counted string cannot fall back to its key.
    static func plural(_ key: String, in language: Lang) -> [String: String]? {
        switch language {
        case .en: return englishPlurals[key]
        case .ru: return russianPlurals[key]
        }
    }

    // MARK: - Russian

    private static let russian: [String: String] = [
        "#RRGGBB or none": "#RRGGBB или нет",
        "%1$@ exited with code %2$d": "%1$@ завершился с кодом %2$d",
        "%1$@ has no %2$@ to lend": "%1$@ не может одолжить рисунок: %2$@",
        "%1$@ has no colour %2$d": "у %1$@ нет цвета %2$d",
        "%@ has no night form: a pattern needs an ink and a background before night can be added — give it a background first":
            "у %@ нет ночной формы: узору нужны краска и фон, прежде чем добавлять ночь — сначала задайте ему фон",
        "%@ already covers that": "%@ уже включает это",
        "%@ already has a section — press ⏎ to change it": "у %@ уже есть секция — ⏎, чтобы изменить",
        "%@ could not be decoded": "%@ не удалось разобрать",
        "%@ could not be read": "не удалось прочитать %@",
        "%@ could not be read as a picture. PNG, JPEG, TIFF, GIF and BMP work; SVG works where the system can draw it.":
            "%@ не удалось прочитать как картинку. PNG, JPEG, TIFF, GIF и BMP годятся; SVG — там, где система умеет его нарисовать.",
        "%@ has no .osm.pbf download — pick one of its sub-regions":
            "у %@ нет файла .osm.pbf — выберите один из вложенных регионов",
        "%@ has no Xpm block to change": "у %@ нет блока Xpm, который можно изменить",
        "%@ has no downloadable extract": "у %@ нет выгрузки для скачивания",
        "%@ has no extract of its own — open it and mark inside":
            "у %@ нет собственной выгрузки — откройте его и отмечайте внутри",
        "%@ has to be installed by hand": "%@ нужно установить вручную",
        "%@ holds no TYP": "в %@ нет TYP",
        "%@ in all": "всего %@",
        "%@ installed": "%@ установлен",
        "setup": "настройка",
        "%d to install": "установить: %d",
        "did not finish": "не завершилось",
        "try again": "повторить",
        "kmap needs a couple of things first": "сначала kmap нужно кое-что доустановить",
        "A map is compiled by mkgmap, which is a Java program, so both have to be on this machine. kmap fetches them into %@ and changes nothing else.":
            "Карту собирает mkgmap — программа на Java, поэтому нужны обе. kmap скачает их в %@ и больше ничего на машине не изменит.",
        "something is still missing": "чего-то всё ещё не хватает",
        "Everything is in place — press ⏎ to build.":
            "Всё на месте — нажмите ⏎, чтобы собрать.",
        "creating a private Python environment": "создание отдельного окружения Python",
        "installing pyhgtmap": "установка pyhgtmap",
        "building the patched mkgmap": "сборка mkgmap с патчем",
        "looking up the current Java %d build": "поиск текущей сборки Java %d",
        "%1$@ — %2$@": "%1$@ — %2$@",
        "checking the download": "проверка загруженного файла",
        "unpacking": "распаковка",
        "Java ready — %@": "Java готова — %@",
        "removing the Java kmap installed": "удаление Java, установленной kmap",
        "kmap installed no Java of its own": "kmap не устанавливал свою Java",
        "removed": "удалено",
        "no Java build is published for this kind of machine":
            "для этой платформы сборки Java не публикуются",
        "Adoptium listed no Java %d build for this machine":
            "Adoptium не предлагает сборку Java %d для этой машины",
        "the download does not match its published checksum (expected %1$@, got %2$@)":
            "загруженный файл не сходится с опубликованной контрольной суммой (ожидалось %1$@, получено %2$@)",
        "the downloaded archive holds no java": "в загруженном архиве нет java",
        "%@ is already installed": "%@ уже установлен",
        "%@ is back as it was imported": "%@ вернулся к тому, что было при импорте",
        "%@ is neither a TYP nor a Garmin .img": "%@ — это ни TYP, ни Garmin .img",
        "%@ is not a #RRGGBB colour": "%@ — не цвет вида #RRGGBB",
        "%@ is a folder of your own, which kmap does not replace: rename it":
            "%@ — ваша собственная папка, kmap её не заменяет: переименуйте папку",
        "%@ is kept in a code page kmap cannot read, which has no room for %@":
            "%@ записан в кодовой странице, которую kmap не поддерживает: символа «%@» в ней нет",
        "%@ is not a type code — write it as 0x2f01": "%@ — не код типа, его пишут как 0x2f01",
        "%@ is now the default": "%@ теперь по умолчанию",
        "%@ looking for more on your drives": "%@ поиск на ваших дисках продолжается",
        "%@ missing": "%@ не найден",
        "%@ needs pyhgtmap — open Toolchain to install it, or pick copernicus1/copernicus3 or view1/view3":
            "для %@ нужен pyhgtmap — установите его в «Инструментах» или выберите copernicus1/copernicus3 либо view1/view3",
        "%@ searching your drives…": "%@ поиск на ваших дисках…",
        "%@ will be rewritten from the binary kept when it was imported. Everything changed in it since is lost.":
            "%@ будет переписан из бинарника, сохранённого при импорте. Всё, что менялось в нём с тех пор, пропадёт.",
        "%@.gpi alongside the map": "%@.gpi рядом с картой",
        "%@: no such file": "%@: файла нет",
        "%d available": "%d доступно",
        "%d by choice": "%d намеренно",
        "%d not": "%d нет",
        "%d of %d": "%d из %d",
        "%d of %d styled": "оформлено %d из %d",
        "%d styled": "оформлено %d",
        "%d suggested": "предлагается %d",
        "%d unused": "%d не используется",
        "%d/%d ready": "%d/%d готово",
        "1251 for Cyrillic names, 1252 for the rest": "1251 для кириллических названий, 1252 для остальных",
        "A .gpi beside the map, holding every object that has an OSM description. The only Garmin format with a real description field.":
            "Файл .gpi рядом с картой, со всеми объектами, у которых есть описание в OSM. Единственный формат Garmin с настоящим полем описания.",
        "A .img has its TYP lifted out here — there is no need to unpack it first. `~` is expanded.":
            "У .img TYP извлекается прямо здесь — распаковывать заранее не нужно. `~` раскрывается.",
        "kmap works with a copy in its own folder and does not touch the original again. The style keeps working even if the source file was on a removable drive.":
            "kmap работает с копией в своей папке и больше не обращается к оригиналу. Стиль продолжит работать, даже если исходный файл лежал на съёмном диске.",
        "A drawing comes from a picture on disk, or from another style whose TYP is readable — a compiled one has nothing to offer until it is imported, which decompiles it.":
            "Рисунок берётся из картинки на диске или из другого стиля с читаемым TYP — скомпилированному нечего одолжить, пока его не импортировали, а импорт его декомпилирует.",
        "A map needs Java and mkgmap. Everything kmap installs lives under %@.":
            "Для сборки нужны Java и mkgmap. Всё, что kmap устанавливает сам, лежит в %@.",
        "A picture is read at %@ — the size of the drawing it would replace. PNG, JPEG, TIFF, GIF and BMP work, and SVG where the system can draw it. `~` is expanded.":
            "Картинка читается в размере %@ — это размер рисунка, который она заменит. PNG, JPEG, TIFF, GIF и BMP годятся, SVG — там, где система умеет его нарисовать. `~` раскрывается.",
        "A picture on disk — PNG, JPEG, SVG…": "Картинка на диске — PNG, JPEG, SVG…",
        "A profile is a saved set of build settings. Pick one on the New map screen and every field fills in from it. Anything changed after that applies to the current map only — the profile itself stays as it was.":
            "Профиль — сохранённый набор настроек сборки. Выберите профиль на экране «Новая карта», и все поля заполнятся из него. Дальнейшие изменения касаются только текущей карты — сам профиль остаётся прежним.",
        "A profile is edited on this page only. Changes made on the New map screen apply to one map and do not touch the profile.":
            "Профиль редактируется только на этой странице. Изменения на экране «Новая карта» действуют на одну карту и профиль не меняют.",
        "A style is two things: the rules that turn OSM tags into Garmin types, and a TYP file that says how those types are drawn. kmap ships the rules; the look comes from your library.":
            "Стиль — это две вещи: правила, которые превращают теги OSM в типы Garmin, и файл TYP, который говорит, как эти типы рисовать. Правила входят в kmap; оформление берётся из вашей библиотеки.",
        "Amenities": "Удобства",
        "Aviation": "Авиация",
        "Background": "Фон",
        "Build map": "Собрать карту",
        "Build one from the main menu. Finished maps land here as .img files; copy one to Garmin/ on the device or its SD card to install it.":
            "Соберите первую из главного меню. Готовые карты попадают сюда файлами .img; скопируйте нужный в Garmin/ на приборе или на его карте памяти, чтобы установить.",
        "Cached elevation": "Кэш высот",
        "Cached extracts": "Кэш выгрузок",
        "Casing": "Обводка",
        "Check tools and disk": "Проверка инструментов",
        "Update tools": "Обновление инструментов",
        "Data updates": "Обновление данных",
        "Two roads can meet on screen without sharing a point — to the router that is a dead end. kmap joins forgotten road ends closer than %d m, and only where there is no way round at all.":
            "Две дороги могут визуально сходиться на экране, но не иметь общей точки — для роутера это тупик. kmap соединяет забытые концы дорог ближе %d м друг от друга и только там, где объехать этот участок нельзя.",
        "It never joins through a building, a fence or a hedge: whether a plot can be crossed is OSM's to say. Where the gap crosses a kerb or a step, kmap adds a thin dotted line, and the map shows that the gap was mended for you.":
            "Никогда не соединяет сквозь здание, забор или изгородь: можно ли пройти через участок, определяет OSM. Если разрыв идёт через бордюр или ступеньку, kmap добавляет тонкий пунктир на карту, это означает, что разрыв исправлен автоматически.",
        "update": "обновить",
        "newer one published %@ — press u": "опубликована новая версия %@ — нажмите u",
        "%@ is already the published one": "%@: более новой версии нет",
        "%@ is not something kmap updates": "%@ kmap не обновляет",
        "still checking…": "проверка ещё идёт…",
        "how often a build asks whether the coastline and boundary packs have been republished":
            "как часто сборка спрашивает, не переиздали ли данные береговой линии и границ",
        "every build": "при каждой сборке",
        "once a week": "раз в неделю",
        "once a month": "раз в месяц",
        "every six months": "раз в полгода",
        "once a year": "раз в год",
        "never": "никогда",
        "updates are off": "обновления выключены",
        "checking for newer data": "проверка обновлений",
        "nothing this build reads": "этой сборке нечего обновлять",
        "up to date": "обновлений нет",
        "kept what was already here": "оставлено как было",
        "one kept": "одно оставлено",
        "not downloaded": "не скачано",
        "one for the device, one for the computer": "один для прибора, другой для компьютера",
        "Coastlines": "Береговые линии",
        "Code page": "Кодовая страница",
        "Colour": "Цвет",
        "Colour %d": "Цвет %d",
        "Colour %d becomes:": "Цвет %d становится:",
        "Colour 2": "Цвет 2",
        "Compile map": "Сборка карты",
        "Contour lines": "Горизонтали",
        "Contours and DEM": "Горизонтали и DEM",
        "Copy it to Garmin/POI on the device; it opens under Custom POIs.":
            "Скопируйте его в Garmin/POI на приборе; он откроется в разделе Custom POIs.",
        "Could not fetch the Geofabrik index: %@": "Не удалось получить индекс Geofabrik: %@",
        "Custom POI file": "Свой файл POI",
        "Cyrillic": "кириллица",
        "DEM layer": "Слой DEM",
        "Descriptions": "Описания",
        "Download OSM extract": "Загрузка OSM данных",
        "Download elevation": "Загрузка высот",
        "Download streams": "Потоки загрузки",
        "Draw": "Рисовать",
        "Draw order — which polygon is painted over which": "Порядок отрисовки — какой полигон поверх какого",
        "Drawing": "Рисунок",
        "Elevation data": "Данные высот",
        "English": "Английские",
        "Family id": "Family id",
        "Fetching the region index from Geofabrik %@": "Загрузка индекса регионов с Geofabrik %@",
        "Fill": "Заливка",
        "Fix summits": "Правка вершин",
        "Folder": "Папка",
        "Format": "Формат",
        "smooth zoom close in; the overview never goes empty":
            "плавное приближение без скачков; обзорная карта не пустеет",
        "Geofabrik index is not in the expected format: %@": "Индекс Geofabrik не в ожидаемом формате: %@",
        "Hide on map": "Скрыть на карте",
        "Historic": "Историческое",
        "House numbers": "Номера домов",
        "How many": "Сколько",
        "I confirm": "подтверждаю",
        "I confirm that the copyright in the files being imported is mine, or that their author has given me permission, or that they are open source and copying and editing them is allowed.":
            "Подтверждаю, что авторские права на импортируемые файлы принадлежат мне, либо автор дал мне разрешение, либо файлы распространяются как open source и копирование и редактирование разрешены.",
        "Important": "Важно",
        "Ink": "Штрих",
        "Interval": "Шаг",
        "JAXA login": "Логин JAXA",
        "JAXA password": "Пароль JAXA",
        "Java heap": "Память Java",
        "Java runtime": "Среда Java",
        "Keep work files": "Рабочие файлы",
        "Label colour": "Цвет подписи",
        "Label size": "Размер подписи",
        "Labels": "Подписи",
        "Land use": "Землепользование",
        "Language": "Язык",
        "Leisure and sport": "Отдых и спорт",
        "Library": "Библиотека",
        "Lines — roads, paths, contours, streams": "Линии — дороги, тропы, горизонтали, ручьи",
        "Local": "Местные",
        "MD5 mismatch — expected %1$@, got %2$@": "MD5 не сошлась — ожидалось %1$@, получено %2$@",
        "Man-made": "Постройки",
        "Moving a rule changes which Garmin type the thing gets — the map, not the drawing. It takes effect on the next build, and undoing it puts the rule back where mkgmap had it.":
            "Перенос правила меняет, какой тип Garmin получит объект — карту, а не рисунок. Он вступает в силу на следующей сборке, а отмена возвращает правило туда, где оно было у mkgmap.",
        "Name (English)": "Название (английское)",
        "Name (Russian)": "Название (русское)",
        "Natural features": "Природа",
        "New colour:": "Новый цвет:",
        "New map": "Новая карта",
        "New type code:": "Новый код типа:",
        "Night version": "Ночная версия",
        "Nodes per tile": "Узлов на плитку",
        "OSM description text is appended to the object's own name.":
            "Текст описания OSM дописывается к собственному названию объекта.",
        "OSM description text is shown when an object is opened, never on the map.":
            "Текст описания OSM показывается при открытии объекта и никогда не рисуется на карте.",
        "Output files": "Выходные файлы",
        "Output folder": "Папка вывода",
        "Overwrite": "Перезапись",
        "the login works": "логин работает",
        "refused — the source is not offered": "отклонён — источник недоступен",
        "could not be checked": "проверить не удалось",
        "%@ — checking the login…": "%@ — проверка логина…",
        "%@ — the login works": "%@ — логин работает",
        "%@ refused these credentials": "%@ отклонил эти данные",
        "%@ did not answer — the login is left as it was": "%@ не ответил — логин оставлен как был",
        "%@ working out what this costs to fetch": "%@ оценка объёма загрузки",
        "%d already in the cache": "%d уже в кэше",
        "nothing to fetch": "загружать нечего",
        "which feature": "какой объект",
        "identifying the rest by place": "дополнительное распознавание",
        "identifying the rest by place in %@": "дополнительное распознавание в %@",
        "nothing matches": "ничего не совпадает",
        "%@ is free. Pick the feature to bind to it — its rule moves here and takes effect on the next build.":
            "%@ свободен. Выберите объект, который привязать сюда — его правило переедет на этот код и вступит в силу со следующей сборки.",
        "free": "свободен",
        "(recommended)": "(рекомендуется)",
        "nothing to fetch — cached or already covered": "загружать нечего — в кэше или уже покрыто",
        "written as one file when it fits a FAT32 card, several when it does not":
            "запишется одним файлом, если влезет в FAT32, иначе несколькими",
        "every size asked": "размер каждого файла запрошен",
        "%@ to download in all": "всего к загрузке: %@",
        "coverage list unavailable — a sampled guess": "список покрытия недоступен — оценка по выборке",
        "about %@ to download": "к загрузке около %@",
        "behind a login, so its size is only known once it starts":
            "требует логина, размер известен только после начала загрузки",
        "the source did not answer, so this is unmeasured": "источник не ответил, размер не измерен",
        "the style folder %@ is gone": "папка стиля %@ больше не существует",
        "%@ is already gone — another kmap deleted it": "%@ уже удалён — это сделал другой экземпляр kmap",
        "the reassignment sheet %@ cannot be read": "лист переназначений %@ не удалось прочитать",
        "%@ is not kmap's work: if an earlier kmap left it, remove it; otherwise pick another work folder":
            "%@ не похожа на рабочую папку kmap: если её оставил прежний kmap, удалите её, иначе выберите другую рабочую папку",
        "mkgmap is being installed or rebuilt — wait for it to end":
            "mkgmap сейчас устанавливается или пересобирается — дождитесь окончания",
        "%@ is not a full path — start it at the root or with ~": "%@ — не полный путь: начните его с корня или с ~",
        "another kmap is installing Java — wait for it to end":
            "другой kmap уже устанавливает Java — дождитесь окончания",
        "builds go on with %1$@, which is as new": "сборки продолжатся на %1$@: она не старее удалённой",
        "builds go on with %1$@, which you named": "сборки продолжатся на %1$@: её указали вы",
        "a build or a patch rebuild is using these tools — try again once it ends":
            "эти инструменты заняты сборкой или пересборкой патча — повторите, когда она закончится",
        "kmap cannot write in the work folder %@ — pick another in Settings or with --work":
            "kmap не может писать в рабочую папку %@ — выберите другую в настройках или через --work",
        "the coverage map could not be read, so which archives this needs is not known":
            "карту покрытия прочитать не удалось, поэтому неизвестно, какие архивы необходимы",
        "no archive covers this ground": "эту территорию не покрывает ни один архив",
        "Theme": "Тема",
        "this installs a system package as root:  %@   —  press y to go ahead":
            "будет установлен системный пакет от root:  %@   —  нажмите y, чтобы продолжить",
        "Day and night": "День и ночь",
        "Day only": "Только день",
        "Night only": "Только ночь",
        "the day colours at any hour, for a receiver that draws night wrongly":
            "всегда дневные цвета — для прибора, который неверно рисует ночные",
        "the night colours at any hour": "всегда ночные цвета, независимо от времени суток",
        "Tile overlap": "Перехлёст плитки",
        "Land overlap": "Перехлёст суши",
        "a tile stops on its frame": "плитка останавливается на рамке",
        "about %@ km": "около %@ км",
        "about %d m": "около %d м",
        "Path to a .typ or a Garmin .img:": "Путь к .typ или к Garmin .img:",
        "Path:": "Путь:",
        "Points — the POI icons": "Точки — значки POI",
        "Polygons — landcover fills and hatches": "Полигоны — заливки и штриховки местности",
        "Press r to try again.": "Нажмите r, чтобы попробовать снова.",
        "Profile": "Профиль",
        "Profiles": "Профили",
        "Railway": "Железная дорога",
        "Repair road ends": "Сшивка дорог",
        "Road features": "Дорожное",
        "Routable": "Маршрутизация",
        "Russian": "Русские",
        "Save profile": "Сохранить профиль",
        "Search index": "Поисковый индекс",
        "Settings": "Настройки",
        "Shops": "Магазины",
        "Size:": "Размер:",
        "Split into tiles": "Нарезка плиток",
        "Standard (4 levels)": "Стандарт (4 уровня)",
        "Style": "Стиль",
        "Styles": "Стили",
        "TYP not readable": "TYP не удалось прочитать",
        "The copy kept at import is not touched, so this can be done again.":
            "Сохранённый при импорте оригинал остаётся без изменений, так что это можно повторить.",
        "The copy stays on this machine. kmap does not publish it and does not send it anywhere; what is done with it afterwards is yours to answer for.":
            "Копия остаётся на этой машине: kmap её не публикует и никуда не отправляет; за то, что будет с ней дальше, отвечаете вы.",
        "The region, the family id and the output folder. The region and the family id are set per map — the device hides maps that share a family id. The folder is set once, in Settings.":
            "Регион, family id и папка вывода. Регион и family id у каждой карты свои — карты с одинаковым family id прибор скрывает. Папка задаётся один раз в настройках.",
        "This TYP is compiled. Its identity reads fine, but its sections cannot be opened yet: mkgmap compiles source into a TYP and offers no way back, so decoding one is work kmap has to do itself. Until then the file can still be built with — it is simply not editable here.":
            "Этот TYP скомпилирован. Его опознавательные данные читаются, а вот секции пока не открыть: mkgmap собирает исходник в TYP и обратной дороги не предлагает, так что декодировать его kmap приходится самому. Пока этого нет, файл всё равно годится для сборки — просто не редактируется здесь.",
        "This file is outside kmap's TYP library, which is the only place kmap writes a TYP. Press ^F for an editable copy.":
            "Этот файл лежит вне библиотеки TYP, а это единственное место, куда kmap пишет TYP. Нажмите ^F, чтобы получить редактируемую копию.",
        "This is kmap's own TYP, and its working copy is rewritten from the shipped one whenever a build finds the two differ — an edit here would be undone without a word. Press ^F for an editable copy in your TYP library.":
            "Это собственный TYP kmap, и его рабочая копия переписывается из поставляемой всякий раз, когда сборка замечает расхождение — правка здесь была бы молча потеряна. Нажмите ^F, чтобы получить редактируемую копию в своей библиотеке TYP.",
        "This style ships no TYP. The device draws every type its own way, so there is nothing here to edit.":
            "У этого стиля нет TYP. Каждый тип прибор рисует по-своему, так что править тут нечего.",
        "Toolchain": "Инструменты",
        "Smooth (8 levels)": "Плавная (8 уровней)",
        "Tourism": "Туризм",
        "USGS login": "Логин USGS",
        "USGS password": "Пароль USGS",
        "Unicode": "Юникод",
        "Work folder": "Рабочая папка",
        "Write output": "Запись результата",
        "Zoom levels": "Уровни зума",
        "a %d m interval over this many tiles makes a large map and a long build":
            "шаг %d м на таком числе плиток даёт большую карту и долгую сборку",
        "a .gpi alongside the map": "файл .gpi рядом с картой",
        "a .gmap folder for BaseCamp as well, about the size of the tiles; the tiles are packed twice":
            "ещё и папка .gmap для BaseCamp, размером примерно с плитки; плитки упаковываются дважды",
        "a line pattern is always 32 wide, and at most 7 deep": "узор линии всегда 32 в ширину и не глубже 7",
        "a polygon hatch is always 32×32": "штриховка полигона всегда 32×32",
        "a tile still overflows Garmin's 16 MB drawing section at %dk nodes per tile — lower Nodes per tile in Settings and build again":
            "плитка всё ещё не помещается в 16-мегабайтную секцию отрисовки Garmin при %dk узлов на плитку — уменьшите «Узлов на плитку» в настройках и соберите снова",
        "mkgmap ran out of memory with %d GB of Java heap — raise Java heap in Settings, or lower Nodes per tile, and build again":
            "mkgmap не хватило памяти при %d ГБ, отведённых Java — увеличьте «Память Java» в настройках или уменьшите «Узлов на плитку» и соберите снова",
        "%d tiles is more than one family's 9999 tile ids — raise Nodes per tile in Settings and build again":
            "%d плиток — больше, чем 9999 номеров плиток одного семейства; увеличьте «Узлов на плитку» в настройках и соберите снова",
        "accept": "принять",
        "add a section": "добавить секцию",
        "add colour": "добавить цвет",
        "add one": "добавить",
        "added %@ — it paints nothing until you use it": "добавлен %@ — он ничего не красит, пока им не воспользуетесь",
        "added a section for %@ — magenta until you draw it": "секция для %@ добавлена — пурпурная, пока не нарисуете",
        // Deleting a section, in the type browser.
        "Delete the section": "Удалить секцию",
        "Its entry in the draw order will be deleted too.": "Строка этого типа в порядке отрисовки тоже будет удалена.",
        "The file is rewritten at once. A new section can be created with a, but the current colours and drawing will be lost.":
            "Файл перезаписывается сразу. Новую секцию можно будет создать клавишей a, но текущие цвета и рисунок будут потеряны.",
        "The section for %@ will be deleted: its drawing, its colours and its names. The device will then draw this type its own way.":
            "Секция для %@ будет удалена: рисунок, цвета и названия. Устройство будет рисовать этот тип по-своему.",
        "delete the section": "удалить секцию",
        "drawn for": "рисуется для",
        "name": "название",
        "section for %@ deleted — the device will draw this type its own way":
            "секция для %@ удалена — устройство будет рисовать этот тип по-своему",
        "type": "тип",
        // The draw order screen.
        "%1$@ is now on level %2$d": "%1$@ теперь на уровне %2$d",
        "%d is not a draw-order level — the lowest is 1": "%d — не уровень отрисовки, самый нижний — 1",
        "a level down / up": "уровень ниже / выше",
        "a level is a number from 1 to %d": "уровень — число от 1 до %d",
        "level %d is already on top of everything": "уровень %d и так поверх всего",
        "level 1 is painted first — there is nothing under it": "уровень 1 рисуется первым — ниже ничего нет",
        "move it there": "перенести туда",
        "move to level": "перенести на уровень",
        "no name": "без названия",
        "not in the draw order — never drawn": "нет в порядке отрисовки — не рисуется вовсе",
        "type a level": "ввести уровень",
        "adds the srtm1 and alos1 elevation sources, which need an account":
            "добавляет источники высот srtm1 и alos1, для них нужен аккаунт",
        "administrative boundaries (~2.5 GB)": "административные границы (~2,5 ГБ)",
        "after the name in brackets — also drawn on the map": "после названия в скобках — рисуется и на карте",
        "a runtime without javac — only the seam patch needs more":
            "рантайм без javac — больше нужно только патчу швов",
        "all files": "все файлы",
        "supported files": "подходящие файлы",
        "built here from source — install a full JDK first":
            "собирается здесь из исходников — сначала установите полный JDK",
        "this Java is a runtime — install a full JDK, or build without the patch":
            "эта Java — рантайм: установите полный JDK или собирайте без патча",
        "Java is needed to build the patch": "для сборки патча нужна Java",
        "already carries": "уже несёт",
        "already in the library as %@ · in styles: c copies it, o brings back the original":
            "уже есть как %@ · в стилях: c — копия, o — вернуть оригинал",
        "already in this style": "уже есть в этом стиле",
        "a true-colour picture is not resized here": "размер полноцветной картинки здесь не изменяется",
        "a picture file gives a point its icon — lines and areas borrow another style's drawing":
            "файл с картинкой задаёт значок точки — для линий и площадей используется рисунок другого стиля",
        "another build is writing into %@ — wait for it to end, or stop it":
            "в %@ уже пишет другая сборка — дождитесь её завершения или остановите её",
        "another build of %@ is running — wait for it to end, or stop it":
            "сборка %@ уже выполняется — дождитесь её завершения или остановите её",
        "another build already uses this name — files carry -%d":
            "это имя уже занято другой сборкой — файлы получают -%d",
        "an older patch — kmap rebuilds it at the next start or build":
            "патч от прежней версии — kmap пересоберёт его сам при запуске или сборке",
        "the answer to the Java lookup is not Adoptium's list — a proxy or a network page in the way?":
            "ответ на поиск Java — не список Adoptium: мешает прокси или страница сети?",
        "built for a newer Java — kmap rebuilds it at the next start or build":
            "собран под более новую Java — kmap пересоберёт его сам при запуске или сборке",
        "rebuilding the mkgmap patch": "пересборка патча mkgmap",
        "kmap is rebuilding the patch on its own — a moment":
            "kmap пересобирает патч — подождите немного",
        "and %d more": "и ещё %d",
        "applied (v%d)": "применён (v%d)",
        "apply": "применить",
        "as address line": "строкой адреса",
        "as phone line (kept out of search)": "строкой телефона (не попадает в поиск)",
        "as postcode line": "строкой почтового индекса",
        "as region line (what OpenTopoMap uses)": "строкой региона (так делает OpenTopoMap)",
        "auto (%d GB)": "авто (%d ГБ)",
        "automatic — as few as fit a card": "по объёму — минимум файлов под карту памяти",
        "back": "назад",
        "back to the list": "к списку",
        "back to the picture": "к картинке",
        "back to the styles": "к списку стилей",
        "back to typing": "обратно к вводу",
        "between 1 and %d — %@": "от 1 до %d — %@",
        "border %d": "обводка %d",
        "borrow a drawing": "одолжить рисунок",
        "borrow one": "одолжить",
        "boundary data": "данные границ",
        "bounds": "рамка",
        "bounds around them all — the map itself covers only the regions themselves":
            "общая рамка вокруг всех — сама карта покрывает только сами регионы",
        "browse": "обзор",
        "build": "сборка",
        "build %d": "собрать %d",
        "building %@": "сборка карты %@",
        "building together": "совместная сборка",
        "built maps": "собрано карт",
        "by path": "по пути",
        "by region": "по региону",
        "cache": "кэш",
        "cached": "в кэше",
        "cancel": "отмена",
        "cancel build": "прервать сборку",
        "cancelled": "прервано",
        "central Europe": "Центральная Европа",
        "change": "изменить",
        "change colour": "изменить цвет",
        "changed for this map only": "изменено только для этой карты",
        "changed on this screen — the map is built with what is on it, and the profile is left as it was":
            "изменено на этом экране — карта соберётся так, как здесь, а профиль останется прежним",
        "changing it later": "изменение профиля",
        "checking %@": "проверка %@",
        "choose": "выбрать",
        "choose a colour": "выбрать цвет",
        "choose a style": "выбор стиля",
        "selected on the New map screen; fills in every field of the form":
            "выбирается на экране «Новая карта» и заполняет все поля формы",
        "city/region for address search (optional, 2.5 GB)": "для поиска по адресу (необязательно, 2,5 ГБ)",
        "clear": "очистить",
        "coastline data": "данные береговой линии",
        "code page": "кодовая страница",
        "code page %d": "кодовая страница %d",
        "code page 1251 — Cyrillic names": "кодовая страница 1251 — названия кириллицей",
        "code page by region": "кодовая страница по региону",
        "colour %d of %d": "цвет %d из %d",
        "compiled TYP": "скомпилированный TYP",
        "editable TYP source": "редактируемый исходник TYP",
        "rules recovered from its map": "правила восстановлены по его карте",
        "compiles OSM data into Garmin .img": "собирает данные OSM в Garmin .img",
        "contains": "содержит",
        "contour lines, DEM, and a style of your choosing": "горизонтали, DEM и стиль на ваш выбор",
        "contours every %d m": "горизонтали через %d м",
        "copied to %@": "скопировано в %@",
        "copied to the Garmin folder on the device or its card":
            "копируется в папку Garmin на приборе или его карте памяти",
        "copy": "копия",
        "copy as": "копия под именем",
        "correct sea and shorelines (optional, 344 MB)": "правильное море и берега (необязательно, 344 МБ)",
        "cost": "объём",
        "could not launch: %@": "не удалось запустить: %@",
        "could not unpack the base style: %@": "не удалось распаковать базовый набор правил: %@",
        "coverage": "покрытие",
        "cropped to %@ — u puts it back": "обрезано до %@ — u вернёт как было",
        "day": "день",
        "day / night": "день / ночь",
        "default": "по умолчанию",
        "delete": "удалить",
        "delete %@?  (y/n)": "удалить «%@»?  (y/n)",
        "delete %@? the file goes for good  (y/n)": "удалить %@? файл будет удалён безвозвратно  (y/n)",
        "deleted": "удалено",
        "could not delete: %@": "не удалось удалить: %@",
        "could not save the settings: %@": "не удалось сохранить настройки: %@",
        "%@ not found — pick a style": "%@ не найден — выберите стиль",
        "a build or a download is running — clear the cache once it ends":
            "идёт сборка или загрузка — очистите кэш, когда она закончится",
        "Clear the cache": "Очистить кэш",
        "press it again to leave without saving": "нажмите ещё раз, чтобы выйти без сохранения",
        "Leave the recovery": "Выход из восстановления",
        "The look read from this map is not saved: leaving drops it, and reading it again takes as long.":
            "Прочитанный с карты вид не сохранён: при выходе он будет потерян, а повторное чтение займёт столько же времени.",
        "leave": "выйти",
        "%@ will be rewritten with this map's look. Everything changed in it since, and its reassignment list, is lost.":
            "%@ будет переписан видом этой карты. Все изменения, внесённые в него с тех пор, и список переназначений будут потеряны.",
        "leave without saving": "выйти без сохранения",
        "stay": "остаться",
        "choose the zoom levels": "выбрать уровни масштаба",
        "Another set of zoom levels": "Другой набор уровней",
        "%1$@ moves %2$d kind(s) of feature on these levels. On %3$@ a level means another scale, so every row goes back to what the style does.":
            "%1$@ переносит на этих уровнях виды объектов (%2$d). В наборе «%3$@» уровень означает другой масштаб, поэтому все строки вернутся к тому, что задаёт стиль.",
        "back to the map's settings": "назад к настройкам карты",
        "this map has changes of its own — ⏎ picks a profile and drops them":
            "у этой карты свои изменения — ⏎ выберет профиль и сбросит их",
        "⏎ deletes %@ — any other key keeps it": "⏎ удаляет %@ — любая другая клавиша отменяет",
        "another install is putting its tools in place — try again in a moment":
            "другая установка размещает свои инструменты — повторите через минуту",
        "the cache is empty — nothing to clear": "кэш пуст — очищать нечего",
        "family id %d is not 1000 to 9999, which mkgmap's 8-digit tile ids need":
            "номер семейства %d вне 1000–9999, а mkgmap нужны 8-значные номера плиток",
        "Replace the drawing": "Заменить рисунок",
        "replace": "заменить",
        "%@ keeps no copy of the drawing it has now: once replaced, it is gone.":
            "%@ не хранит копию текущего рисунка: после замены его нельзя вернуть.",
        "the night picture too, in these colours": "и ночная картинка, в тех же цветах",
        "a pattern is painted with its day ink and background — the night pair colours the same pixels":
            "узор рисуется дневными чернилами и фоном — ночная пара цветов окрашивает те же пиксели",
        "a pattern has an ink and a background, by day and by night — change one with c":
            "у узора есть чернила и фон, днём и ночью — меняйте их клавишей c",
        "night shares the day drawing — add the colour by day, then change it here":
            "ночь использует дневной рисунок — добавьте цвет днём, а здесь измените его",
        "a line or polygon has at most 4 colours: an ink and a background, by day and by night":
            "у линии или полигона не больше 4 цветов: чернила и фон, днём и ночью",
        "the only colour of a line or polygon cannot be clear":
            "единственный цвет линии или полигона не может быть прозрачным",
        "the night ink and background cannot both be clear":
            "ночные чернила и фон не могут быть прозрачными одновременно",
        "the day ink and background cannot both be clear":
            "дневные чернила и фон не могут быть прозрачными одновременно",
        "remove %@? press y to go ahead": "удалить %@? нажмите y, чтобы продолжить",
        "moved to %1$@, with %2$d profile(s) using it — the rows are back to what the style does":
            "переведён на %1$@ вместе с профилями, которые его используют (%2$d) — строки снова как в стиле",
        "kmap cannot open its lock files in %@, so it cannot tell whether a build writes there":
            "kmap не может открыть свои файлы блокировок в %@, поэтому не может определить, пишет ли туда сборка",
        "kmap is checking the patch — a moment": "kmap проверяет патч — подождите немного",
        "that is the type it has already": "этот тип уже назначен",
        "the extracts kmap holds around this map do not cover what it draws (%@)":
            "имеющиеся у kmap выгрузки вокруг этой карты не покрывают всё, что она рисует (%@)",
        "%@ of elevation tiles will be deleted. A build fetches them again, which can take hours.":
            "Будут удалены плитки рельефа (%@). Сборка загрузит их снова, это может занять часы.",
        "%@ of downloaded extracts will be deleted. A build downloads them again.":
            "Будут удалены загруженные выгрузки (%@). Сборка загрузит их снова.",
        "mkgmap knows no code page %d — pick another for this map or its profile":
            "mkgmap не поддерживает кодовую страницу %d — выберите другую для карты или её профиля",
        "could not save the login: %@": "не удалось сохранить логин: %@",
        "%@ is not the file kmap knows (SHA-256 %@) — refused":
            "%@ — не тот файл, который знает kmap (SHA-256 %@), отклонён",
        "the patch is built for mkgmap r%@ only, and this mkgmap is r%@":
            "патч собирается только для mkgmap r%@, а здесь r%@",
        "pyhgtmap's file cannot hold this value: a line break, square brackets, or a quote before # or ;":
            "файл pyhgtmap не может хранить значения: перевод строки, квадратные скобки или кавычка перед # или ;",
        "%@ is not UTF-8 text, so it is left as it is": "%@ — не текст в UTF-8, файл оставлен как есть",
        "deleted %@": "удалён %@",
        "deleted %@ — it was the default, which is now %@": "удалён %@ — он был по умолчанию, теперь это %@",
        "deleted %@ — nothing is left to be the default": "удалён %@ — выбора по умолчанию больше нет",
        "deleted %@ — the build screen now opens on %@": "удалён «%@» — теперь экран сборки открывается на «%@»",
        "descriptions": "описания",
        "output folder": "путь",
        "device default": "как решит прибор",
        "device default, on purpose": "как решит прибор, и это намеренно",
        "different size — it will be used as it is, not scaled to fit":
            "другой размер — возьмётся как есть, без подгонки",
        "done": "готово",
        "downloaded .osm.pbf extracts kept for reuse": "скачанные .osm.pbf — хранятся для повторных сборок",
        "drawing replaced — %@, %@": "рисунок заменён — %@, %@",
        "duplicate": "копия",
        "edit": "править",
        "editable copy": "редактируемая копия",
        "editable source": "редактируемый исходник",
        "elevation": "высоты",
        "downloaded elevation data; cleared, it is downloaded again":
            "скачанные данные высот; после очистки скачаются заново",
        "empty": "пусто",
        "english": "английские",
        "eorc.jaxa.jp/ALOS/en/aw3d30 — unlocks alos1, also 30 m": "eorc.jaxa.jp/ALOS/en/aw3d30 — alos1, 30 м",
        "ers.cr.usgs.gov/register — unlocks srtm1, 30 m instead of 90 m":
            "ers.cr.usgs.gov/register — srtm1, 30 м вместо 90",
        "extract": "выгрузка",
        "failed": "не удалось",
        "family": "семейство",
        "family %d": "семейство %d",
        "family %d already here": "семейство %d уже есть",
        "family id %d": "family id %d",
        "field": "поле",
        "file": "файл",
        "filter": "фильтр",
        "finished maps, each build in its own dated folder": "готовые карты, каждая сборка в своей папке с датой",
        "font style left to the device": "шрифт оставлен на усмотрение прибора",
        "font style: %@": "шрифт: %@",
        "from": "откуда",
        "from a file": "из файла",
        "from which style": "из какого стиля",
        "grid": "сетка",
        "grid · sliders · style": "сетка · ползунки · стиль",
        "grown to %@, the new ground clear": "увеличено до %@, новое поле прозрачное",
        "hide all shown": "скрыть всё показанное",
        "hide on map": "скрыть на карте",
        "hide the preview": "скрыть превью",
        "hue": "тон",
        "import": "импорт",
        "import a TYP": "импорт TYP",
        "map": "карта",
        "recover the style": "восстановление стиля",
        "Recover the style?": "Восстановить стиль?",
        "A TYP records how type codes are drawn. The map records the other half: which"
            + " code stands for a forest or a trunk road. kmap can read that out of the"
            + " map — builds with this style then look the same as the original.":
            "В TYP записано, как рисуются коды типов. В карте записана вторая половина:"
            + " какой код обозначает лес, а какой — магистраль. kmap может прочитать это"
            + " из карты — тогда сборки с этим стилем выглядят так же, как исходная.",
        "The whole map is read, which takes a few minutes.":
            "Читается вся карта, это занимает несколько минут.",
        "Only the drawing": "Только оформление",
        "A TYP file holds the drawing: colours, patterns, icons. Which code stands for a"
            + " forest or a trunk road is not in it — that is read out of the map itself.":
            "В TYP-файле лежит оформление: цвета, узоры, значки. Какой код обозначает лес,"
            + " а какой магистраль — в нём этого нет, это читается из самой карты.",
        "So recovering the style is not available for a TYP on its own. If you have the"
            + " .img this file came from, import that instead: kmap takes the TYP out of"
            + " it and can work the codes out too.":
            "Поэтому для TYP самого по себе восстановление стиля недоступно. Если у вас"
            + " есть .img, из которого этот файл, импортируйте его: kmap достанет TYP"
            + " оттуда сам и вдобавок сможет разобрать коды.",
        "import anyway": "всё равно импортировать",
        "the download server did not answer in time — try again, or later if it is busy":
            "сервер загрузок не ответил вовремя — повторите сейчас или позже, если он занят",
        "no connection to the download server — check the network and try again":
            "нет связи с сервером загрузок — проверьте сеть и повторите",
        "the download did not go through: %@": "скачать не удалось: %@",
        "recover": "восстановить",
        "recover from its map": "восстановить по карте",
        "from map %@": "из карты %@",
        "not now": "не сейчас",
        "start": "начать",
        "discard": "не сохранять",
        "A TYP records how type codes are drawn. It does not record which code this map"
            + " used for a forest or a trunk road.":
            "В TYP записано, как рисуются коды типов. В нём не записано, каким кодом эта"
            + " карта обозначила лес или магистраль.",
        "kmap works that out from the map itself: every element is looked up in OSM data"
            + " by its geometry, and the code it was drawn with is tied to the thing it"
            + " stands for.":
            "kmap выясняет это по самой карте: каждый её элемент находится в данных OSM"
            + " по геометрии, и код, которым он нарисован, привязывается к тому, что он"
            + " обозначает.",
        "What comes out is kept with the imported TYP, and every build with that style"
            + " applies it — the map comes out looking the way the original did.":
            "Разобранное хранится вместе с импортированным TYP, и каждая сборка с этим"
            + " стилем его применяет — карта выходит такой же на вид, как исходная.",
        "Reading the whole map takes a few minutes; you can stop it at any point.":
            "Чтение всей карты занимает несколько минут; прервать можно в любой момент.",
        "recovering %@": "восстановление %@",
        "cancelled — nothing was kept": "отменено — ничего не сохранено",
        "preparing the map reader": "подготовка чтения карты",
        "reading the map": "чтение карты",
        "matching against %@": "сопоставление с %@",
        "matching against OSM data": "сопоставление с данными OSM",
        "working out what the codes mean": "разбор кодов",
        "Download a region?": "Скачать регион?",
        "No OSM data on this machine matches this map. Recovering the style does not need"
            + " the whole map covered — the codes a style uses are used everywhere it"
            + " draws, so one region inside the map is enough to read them.":
            "Данных OSM под эту карту на машине нет. Восстановлению не нужна вся площадь"
            + " карты: коды стиля используются везде, где он рисует, поэтому одного"
            + " региона внутри карты достаточно, чтобы их прочитать.",
        "The first is what kmap would take; it lands in the same cache a build reads, so"
            + " the next build has it too.":
            "Первый — тот, что kmap возьмёт; он ложится в тот же кэш, которым пользуется"
            + " сборка, так что следующей сборке достанется тоже.",
        "download": "скачать",
        "downloading %@": "скачивание %@",
        "no region kmap can download overlaps this map (%@)":
            "ни один доступный для скачивания регион не пересекается с этой картой (%@)",
        "it did not work out": "не получилось",
        "TYP family %d": "семейство TYP %d",
        "files written": "записанные файлы",
        "clearing…": "очистка…",
        "no file manager to show %@ in": "нет файлового менеджера, чтобы показать %@",
        "the file holds no map tiles — is it a Garmin .img?": "в файле нет плиток карты — это .img от Garmin?",
        "no such map: %@": "нет такой карты: %@",
        "no such extract: %@": "нет такой выгрузки: %@",
        "%@ cannot be read: %@": "%@ не удалось прочитать: %@",
        "Nothing to save: this map carries no look to take.":
            "Сохранять нечего: в этой карте нет оформления, которое можно перенести.",
        "recovered": "восстановленный",
        "%@ now draws this map's look": "%@ теперь рисует оформление этой карты",
        "nothing identified": "ничего не опознано",
        "draws several things": "рисует разное",
        "no rule for it": "правила нет",
        "too few sightings": "мало наблюдений",
        "gmap — for BaseCamp": "gmap — для BaseCamp",
        "img — for the device": "img — для прибора",
        "img and gmap": "img и gmap",
        "installed on the computer; BaseCamp needs no device":
            "устанавливается на компьютер; BaseCamp обходится без прибора",
        "in library": "в библиотеке",
        "in use": "текущий",
        "index unavailable": "индекс недоступен",
        "inspect": "смотреть",
        "install": "установить",
        "install all missing": "установить всё недостающее",
        "install with: %@": "установите через: %@",
        "Windows 10 version 1803 and later include tar — this one has none":
            "в Windows 10 начиная с 1803 tar входит в состав системы — на этой машине его нет",
        "needs python3 — %@": "нужен python3 — %@",
        "unpacks everything else on this page": "распаковывает всё остальное на этой странице",
        "code page 1252 cannot hold Cyrillic — set 1251 if the names here are in it":
            "кодовая страница 1252 не поддерживает кириллицу — выберите 1251, если названия здесь на кириллице",
        "worth knowing": "что важно знать",
        "a saved set of the choices on this screen": "сохранённый набор настроек с этого экрана",
        "code page %d · family %d · product %d": "кодовая страница %d · семейство %d · продукт %d",
        "%d polygon(s), %d line(s), %d point(s); %d of %d read exactly":
            "%d полигонов, %d линий, %d точек; %d из %d прочитаны точно",
        "draw order": "порядок отрисовки",
        "no TYP inside": "внутри нет TYP",
        "wrote %@ (%@)": "записано %@ (%@)",
        "%d tile(s) cover their own box, %d sample(s) checked":
            "%d плиток покрывают свою рамку, проверено %d точек",
        "%d of %d sample(s) fall in no tile — blank ground at %@":
            "%d из %d точек не попали ни в одну плитку — пустой участок в %@",
        "%d of %d sample(s) fall in no tile": "%d из %d точек не попали ни в одну плитку",
        "no map tiles found": "плиток карты не найдено",
        "  ... and %d more": "  ... и ещё %d",
        "mkgmap is needed to read the rules the catalogue is built from — run `kmap install mkgmap`":
            "чтобы прочитать правила, из которых собирается каталог, нужен mkgmap — выполните `kmap install mkgmap`",
        "%@: %d hideable feature(s) across %d key(s)":
            "%@: %d скрываемых объектов по %d ключам",
        "install %@ with this machine's package manager": "установите %@ пакетным менеджером этой машины",
        "download %@ from %@": "скачайте %@ с %@",
        "no package manager kmap knows was found — install %@ by hand":
            "не нашёлся ни один известный kmap пакетный менеджер — установите %@ вручную",
        "%1$@ has no name for %2$@ that kmap knows": "kmap не знает, как %2$@ называется в %1$@",
        "this needs a root password, which kmap cannot ask for from here. Run:  %@":
            "нужен пароль root, а спросить его отсюда kmap не может. Выполните:  %@",
        "installing %1$@ with %2$@": "установка %1$@ через %2$@",
        "%@ is not where it said it was": "%@ не найден там, где только что был",
        "kmap can install this": "kmap может установить это сам",
        "installing %@": "установка %@",
        "joins ends within %d m that block a route": "сшивает концы ближе %d м там, где без этого нет маршрута",
        "keep": "оставить",
        "keep intermediate tiles and contours after a build": "хранить промежуточные плитки и горизонтали после сборки",
        "keep it": "оставить",
        "kept in ~/.pyhgtmap/config.yaml, readable only by you":
            "лежит в ~/.pyhgtmap/config.yaml, читается только вами",
        "kept until you change it · applies to the map and to the custom POI file":
            "хранится, пока не поменяете · действует и на карту, и на файл своих POI",
        "labels: %@": "подписи: %@",
        "leave as is": "оставить как есть",
        "leave empty and kmap finds it on its own": "оставьте пустым — kmap найдёт его сам",
        "experimental — hides the seams between tiles and decides what covers what":
            "экспериментальный — убирает швы между плитками и задаёт, что чем перекрывается",
        "nothing was imported": "ничего не импортировано",
        "only a style in your library can be copied": "копировать можно только стиль из своей библиотеки",
        "only a style in your library can be restored": "восстановить можно только стиль из своей библиотеки",
        "remove": "снять",
        "%@ cannot be removed": "%@ снять нельзя",
        "%@ removed": "%@ снят",
        "restore": "вернуть",
        "restore the original": "вернуть оригинал",
        "take an icon from a file": "взять иконку из файла",
        "the patched mkgmap is not there": "mkgmap с патчем не установлен",
        "removing the patched mkgmap": "снятие патча mkgmap",
        "removed — builds will use the stock mkgmap":
            "снят — сборки пойдут на обычном mkgmap",
        "library": "библиотека",
        "lifted out of %@": "извлечён из %@",
        "lightness": "светлота",
        "lines": "линии",
        "load": "загрузить",
        "loading": "загрузка",
        "loading %@": "загрузка %@",
        "log": "журнал",
        "looking…": "поиск…",
        "make current": "сделать текущим",
        "make default": "сделать основным",
        "maps you have already built": "карты, которые вы уже собрали",
        "mark": "отметить",
        "mark several": "отметить несколько",
        "memory handed to mkgmap; 0 means auto": "память, отдаваемая mkgmap; 0 — автоматически",
        "menu": "меню",
        "missing tool: %@": "нет инструмента: %@",
        "mkgmap did not produce gmapsupp.img for %@": "mkgmap не создал gmapsupp.img для %@",
        "mkgmap did not produce the .gmap folder": "mkgmap не создал папку .gmap",
        "mkgmap left %@ cut short — is the disk full?":
            "mkgmap не дописал %@ — возможно, на диске закончилось место",
        "mkgmap seam patch": "патч швов mkgmap",
        "mkgmap's default — smaller maps, coarser zoom steps": "по умолчанию у mkgmap — карты меньше, шаги зума грубее",
        "mkgmap, the seam patch, elevation data": "mkgmap, патч швов, данные высот",
        "mkgmap.jar is needed to unpack the base style": "чтобы распаковать базовый набор правил, нужен mkgmap.jar",
        "move": "перейти",
        "moving": "перенос",
        "name it": "название",
        "needs Java first": "сначала нужна Java",
        "never emitted": "не выдаётся",
        "new": "создать",
        "new map": "новая карта",
        "next": "дальше",
        "night": "ночь",
        "night colours added, the same as day to start — now change them":
            "ночные цвета добавлены, для начала как дневные — теперь поменяйте их",
        "night shares the day drawing — change its colours, not its pixels":
            "ночь использует дневной рисунок — меняйте её цвета, а не пиксели",
        "night started from the day drawing — change its colours, then save":
            "ночь начата с дневного рисунка — поменяйте цвета и сохраните",
        "night version added, drawn the same — now change its colours":
            "ночная версия добавлена, нарисована так же — теперь поменяйте цвета",
        "night — same drawing, its own colours": "ночь — тот же рисунок, свои цвета",
        "night: the same drawing, its own colours": "ночь: тот же рисунок, свои цвета",
        "night: drawn apart from the day, kept as it is": "ночь: нарисована отдельно от дня, оставлена без изменений",
        "no .hgt elevation tiles were downloaded, so the DEM layer cannot be built":
            "плитки высот .hgt не скачаны, поэтому слой DEM не построить",
        "no DEM": "без DEM",
        "no TYP": "без TYP",
        "no TYP — the device picks the colours": "без TYP — цвета выбирает прибор",
        "road ends are repaired without elevation data — a drop between them may go unseen. Turning the DEM layer on is recommended":
            "концы дорог чинятся без данных высот — перепад между ними может остаться незамеченным. Рекомендуется включить слой DEM",
        "no bounding box known for %@, so elevation data cannot be fetched":
            "для %@ неизвестна рамка, поэтому данные высот не скачать",
        "no contour data was produced for %@ — the elevation source may not cover it":
            "для %@ горизонтали не построены — источник высот может его не покрывать",
        "no contours": "без горизонталей",
        "no drawing": "рисунка нет",
        "nothing here answers to \"%@\"": "по запросу «%@» здесь ничего не найдено",
        "no maps built yet": "карт пока не собрано",
        "the rule set is not unpacked yet — build a map once, then come back":
            "набор правил ещё не распакован — соберите карту один раз и вернитесь",
        "no rule in this style emits it — nothing to move":
            "ни одно правило этого стиля его не выдаёт — переносить нечего",
        "no rule in this style emits this code": "ни одно правило этого стиля не выдаёт этот код",
        "no styles found": "стилей не найдено",
        "no sub-regions here": "вложенных регионов нет",
        "none": "нет",
        "none yet": "пока ни одной",
        "none — the day drawing is used after dark": "нет — ночью используется дневной рисунок",
        "not a TYP file — the GARMIN TYP signature is missing": "это не файл TYP — нет подписи GARMIN TYP",
        "not a type this kind of element can take": "этот тип недопустим для элементов этого вида",
        "not downloadable": "не скачивается",
        "not found": "не найден",
        "not installed": "не установлен",
        "not needed for copernicus, fabdem, gedtm, view1 or view3":
            "для copernicus, fabdem, gedtm, view1 и view3 не нужен",
        "not set": "не задан",
        "not set — 3 arc-second data only": "не задан — только данные в 3 угловые секунды",
        "not styled by this TYP — the device draws its own": "этот TYP его не оформляет — прибор рисует своё",
        "note": "заметка",
        "nothing": "ничего",
        "nothing found — press ⇥ and type a path instead": "ничего не нашлось — нажмите ⇥ и введите путь",
        "nothing here — the rule set has not been unpacked yet": "здесь пусто — набор правил ещё не распакован",
        "nothing known about \"%@\"": "про «%@» ничего не известно",
        "nothing left to install": "устанавливать больше нечего",
        "nothing matches \"%@\"": "ничего не нашлось по «%@»",
        "nothing matches — press ⇥ to type a code instead": "ничего не нашлось — нажмите ⇥ и введите код",
        "nothing to undo": "отменять нечего",
        "nothing — ⏎ to choose": "ничего — ⏎, чтобы выбрать",
        "now": "сейчас",
        "off": "выкл",
        "off %@": "с %@",
        "on": "вкл",
        "one file per country, its regions gathered together": "по файлу на страну, её регионы собраны вместе",
        "one file per region, so a region can be left off the card":
            "по файлу на регион, чтобы регион можно было не копировать на карту памяти",
        "one per country": "по одному на страну",
        "one per region": "по одному на регион",
        "only a style in your library can be deleted": "удалить можно только стиль из вашей библиотеки",
        "only a style in your library can be renamed": "переименовать можно только стиль из вашей библиотеки",
        "open": "открыть",
        "open the editor": "открыть редактор",
        "open · build": "открыть · собрать",
        "open · save": "открыть · сохранить",
        "other builds kept changing the shared style — build again when they are done":
            "другие сборки меняли общий стиль — повторите сборку после их завершения",
        "output": "вывод",
        "outside the POI range 0x2900–0x30ff — the device will draw it but show no card for it":
            "вне диапазона POI 0x2900–0x30ff — прибор нарисует объект, но карточки для него не покажет",
        "paint": "рисовать",
        "parallel byte-range connections per download": "параллельных байтовых соединений на загрузку",
        "paths, memory, connections": "пути, память, соединения",
        "pick": "взять",
        "pick a colour": "выбрать цвет",
        "pixel by pixel, with the pointer": "пиксель за пикселем, указателем",
        "points": "точки",
        "points/lines/polygons": "точки/линии/полигоны",
        "polygons": "полигоны",
        "polygons missing from the draw order, never drawn: %@":
            "полигоны, которых нет в порядке отрисовки, — не рисуются вовсе: %@",
        "precompiled coastline polygons (~344 MB)": "готовые береговые полигоны (~344 МБ)",
        "prefer the English name where OSM has one": "предпочитать английское название, где оно есть в OSM",
        "prefer the Russian name where OSM has one": "предпочитать русское название, где оно есть в OSM",
        "preview": "превью",
        "product %d": "продукт %d",
        "profile": "профиль",
        "profiles": "профили",
        "quit": "выход",
        "re-check": "проверить снова",
        "re-checking…": "повторная проверка…",
        "read at %d px": "читается в %d px",
        "read at its own size, nothing scaled and no colour lost":
            "прочитано в своём размере, ничего не масштабировано и ни один цвет не потерян",
        "read-only source": "исходник только для чтения",
        "read-only — press ^F on the style screen for an editable copy":
            "только чтение — нажмите ^F на экране стиля, чтобы получить редактируемую копию",
        "ready": "готов",
        "reassign": "перенести",
        "reassign a rule": "перенести правило",
        "refreshing the region index…": "обновление индекса регионов…",
        "the region index is up to date": "индекс регионов актуален",
        "Geofabrik did not answer — the region index kept is from %@":
            "Geofabrik не ответил — используется сохранённый индекс регионов от %@",
        "could not refresh the region index: %@": "не удалось обновить индекс регионов: %@",
        "region": "регион",
        "regions": "регионы",
        "rename": "переименовать",
        "rename to": "новое имя",
        "renamed to %@": "переименован в %@",
        "rescan": "пересканировать",
        "reveal in Finder": "показать в Finder",
        "show in Explorer": "показать в проводнике",
        "open the folder": "открыть папку",
        "revealed %@": "показан %@",
        "runs mkgmap": "запускает mkgmap",
        "russian": "русские",
        "same file, same permissions": "тот же файл, те же права",
        "saturation": "насыщенность",
        "save": "сохранить",
        "save & back": "сохранить и назад",
        "saved": "сохранено",
        "scratch space during a build; emptied when it finishes": "черновики на время сборки; очищаются после неё",
        "scroll log": "листать журнал",
        "detail": "подробности",
        "hide detail": "скрыть подробности",
        "scrolled back %d": "прокручено назад на %d",
        "search": "поиск",
        "select": "выбрать",
        "no other readable style — import one to borrow from it":
            "других читаемых стилей нет — импортируйте, чтобы было откуда взять",
        "server did not report a file size": "сервер не сообщил размер файла",
        "server ignored the range request": "сервер не поддерживает загрузку по диапазонам",
        "server returned HTTP %d": "сервер ответил HTTP %d",
        "settings": "настройки",
        "show all": "показать всё",
        "shown at 1:%d": "показан 1:%d",
        "size": "размер",
        "sliders": "ползунки",
        "upper limit on one map tile; the default suits most machines":
            "предел размера одной плитки; по умолчанию подходит почти всем",
        "solid colours, no pattern": "сплошные цвета, без узора",
        "splitter did not produce what was expected: %@": "splitter выдал неожиданный результат: %@",
        "splitter produced no tiles": "splitter не выдал ни одной плитки",
        "start a pattern from this type's own colour": "начать узор с собственного цвета этого типа",
        "start one": "начать",
        "started a pattern from this type's own colour — save to keep it":
            "узор начат с собственного цвета этого типа — сохраните, чтобы оставить",
        "state": "состояние",
        "stop": "стоп",
        "stopped": "остановлено",
        "style": "стиль",
        "style: %@": "стиль: %@",
        "styles": "стили",
        "take it": "взять",
        "that picture has no pixels in it": "в этой картинке нет ни одного пикселя",
        "that rule has already been reassigned: %@": "это правило уже переносили: %@",
        "the TYP ends in the middle of its header": "TYP обрывается посреди своего заголовка",
        "the build screen opens on %@": "экран сборки открывается на «%@»",
        "the colour you paint with": "цвет, которым рисуете",
        "the data is used exactly as OSM has it": "как в OSM, без сшивки",
        "the file changed on the server while it downloaded": "файл на сервере изменился во время загрузки",
        "the relief is used exactly as measured": "рельеф как измерен, без правки",
        "a summit's cell is lifted to its OSM height": "ячейка вершины поднята до высоты из OSM",
        "the last profile stays — the build screen opens on one":
            "последний профиль удалить нельзя — он нужен экрану сборки",
        "the rule set has not been unpacked yet — run a build once":
            "набор правил ещё не распакован — соберите что-нибудь один раз",
        "the toolchain is incomplete — open Toolchain to finish setting it up":
            "не все инструменты установлены — откройте «Инструменты» и завершите настройку",
        "the interface, not the map — labels are a build choice":
            "язык интерфейса; подписи карты выбираются при сборке",
        "there is no drawing here to edit — borrow one first": "тут нечего рисовать — сначала одолжите рисунок",
        "this TYP already has a %1$@ section for %2$@": "в этом TYP уже есть секция %1$@ для %2$@",
        "this TYP has no %1$@ section for %2$@": "в этом TYP нет секции %1$@ для %2$@",
        "this TYP has no section for %@": "в этом TYP нет секции для %@",
        "this TYP has no section for %@ — press a to add one":
            "в этом TYP нет секции для %@ — нажмите a, чтобы добавить",
        "this TYP has no section for it — the device draws its own idea":
            "в этом TYP для него нет секции — прибор нарисует своё",
        "this exact rule appears more than once in %@; moving it would move every copy":
            "это же правило встречается в %@ не один раз; перенос сдвинул бы все копии",
        "this picture has no room for another colour": "в этой картинке нет места ещё под один цвет",
        "this region has no downloadable extract": "у этого региона нет выгрузки для скачивания",
        "this rule is not in %@ as written — it may come from an include, which cannot be substituted":
            "этого правила нет в %@ в таком виде — возможно, оно из include, а его подменить нельзя",
        "this style has no original kept — nothing was imported to go back to":
            "у этого стиля нет сохранённого оригинала — возвращаться не к чему",
        "this style is read-only — take an editable copy first":
            "стиль только для чтения — сначала сделайте редактируемую копию",
        "tiles from %d": "плитки с %d",
        "to download": "скачать",
        "toggle": "переключить",
        "toolchain": "инструменты",
        "type a code": "ввести код",
        "type a path": "ввести путь",
        "undo": "отменить",
        "unsaved": "не сохранено",
        "unsaved changes — leave anyway? (y/n)": "есть несохранённые изменения — всё равно выйти? (y/n)",
        "up to %@": "до %@",
        "use this one": "взять этот",
        "western Europe": "Западная Европа",
        "what it does not include": "что в него не входит",
        "whatever the device uses": "как решит прибор",
        "whatever the local mappers wrote — Russian in Russia, German in Germany":
            "как записано в OSM — по-русски в России, по-немецки в Германии",
        "where to": "куда",
        "which rule": "какое правило",
        "width %d": "ширина %d",
        "with the DEM layer": "со слоем DEM",
        "without it tiles meet on a line and it shows": "без него плитки сходятся по линии, и это видно",
        "without it, coastlines are derived from the extract and can flood inland at low zoom":
            "без него береговые линии выводятся из выгрузки и на дальнем зуме могут залить сушу",
        "without it, the city and region on an address are a best guess":
            "без них город и регион в адресе определяются приблизительно",
        "would become": "станет",
        "write it as 20x20, or one number for a square": "пишется как 20x20 или одним числом для квадрата",
        "written the way the rule files write it, such as 0x2f01":
            "так, как это пишут в файлах правил, например 0x2f01",
        "yours": "ваш",
        "zoom": "зум",
        "… and %d more": "… и ещё %d",
        "⏎ builds one map · c clears": "⏎ соберёт одну карту · c очистит",
        "⏎ to clear": "⏎ очистить",

        // Zoom plans.
        "Zoom plan": "План зума",
        "Zoom plans": "Планы зума",
        "zoom plan": "план зума",
        "zoom plans": "планы зума",
        "as measured": "как измерено",
        "zoom levels": "уровни зума",
        "name for the copy": "имя копии",
        "new name": "новое имя",
        "level %d": "уровень %d",
        "delete %@?": "удалить %@?",
        "%@ ships with kmap — press c to copy it": "%@ входит в kmap — нажмите c, чтобы скопировать",
        "this plan ships with kmap — copy it to make changes": "этот план входит в kmap — скопируйте его, чтобы менять",
        "deleted %@ — any profile using it goes back to what ships":
            "удалён %@ — профили с ним вернутся к тому, что входит в kmap",
        "no rule set on disk yet — build once and this fills in":
            "набора правил ещё нет на диске — соберите карту, и ступени появятся",
        "A device shows the map at several zoom levels. A zoom plan sets the level where each kind of feature appears: trails, roads, woodland and so on.":
            "Прибор показывает карту на нескольких уровнях зума. План зума задаёт, с какого уровня виден каждый вид объектов: тропы, дороги, лес и так далее.",
        "This plan comes with kmap and cannot be edited. Copy it on the plans page, and the copy is yours to change.":
            "Этот план встроен в kmap, его нельзя изменить. Скопируйте его на странице планов — копию можно менять.",
        "from %@": "с %@",
        "from level %d": "с уровня %d",
        "%d m": "%d м",
        "build a map": "собрать карту",
        "how the map looks — TYP files": "внешний вид карты — файлы TYP",
        "your saved build settings": "сохранённые настройки сборки",
        "what appears at which zoom": "что видно на каком зуме",
        "Pick a region, choose what goes into the map, and press Build. kmap downloads the data, draws contour lines and shaded relief, and writes an .img file ready for the device.":
            "Выберите регион, отметьте, что войдёт в карту, и нажмите «Собрать». kmap скачает данные, построит горизонтали и отмывку рельефа и запишет файл .img, готовый для прибора.",
        "Every map you have built, with its size and date. From here a map can be shown in the file manager, ready to copy to the device, or deleted when it is no longer needed.":
            "Все собранные карты, с размером и датой. Отсюда карту можно открыть в файловом менеджере, чтобы скопировать на прибор, или удалить, когда она больше не нужна.",
        "A style decides how the map looks on the screen: colours, fills, icons. Styles can be edited here or taken from another Garmin map. Without one the device draws the map in its own default colours.":
            "Стиль определяет, как карта выглядит на экране: цвета, заливки, значки. Стиль можно править здесь или взять из другой карты Garmin. Без стиля прибор рисует карту своими цветами.",
        "A profile is a saved set of build settings — one per device, or one per kind of map. Picking a profile fills the whole New map form in one step. The region is chosen each time and is not part of it.":
            "Профиль — сохранённый набор настроек сборки: по одному на прибор или на вид карты. Выбор профиля заполняет всю форму новой карты за один шаг. Регион выбирается каждый раз и в профиль не входит.",
        "A zoom plan sets the zoom level where each kind of feature appears on the device: trails, roads, woodland and so on. The plans that come with kmap are a good starting point; copy one to adjust it.":
            "План зума задаёт, с какого уровня зума на приборе виден каждый вид объектов: тропы, дороги, лес и так далее. Планы из поставки — хорошая основа; скопируйте план, чтобы настроить под себя.",
        "The external programs a build needs: Java, mkgmap and the optional data packs. kmap installs most of this itself and shows the exact command for the rest.":
            "Внешние программы, нужные сборке: Java, mkgmap и необязательные пакеты данных. Большую часть kmap устанавливает сам, а для остального показывает готовую команду.",
        "Folders, memory, download connections, and the language of these screens.":
            "Папки, память, число соединений при загрузке и язык этих экранов.",
        "this TYP declares no draw order": "в этом TYP порядок отрисовки не задан",
        "Polygons are painted level by level: level 1 first, every later level on top of it. Within a level the order does not matter.":
            "Полигоны рисуются по уровням: сначала уровень 1, каждый следующий — поверх. Внутри уровня порядок не важен.",
        "starting": "запуск",
        "reading the extract": "чтение выгрузки",
        "not requested": "не запрошено",
        "preparing": "подготовка",
        "preparing style": "подготовка стиля",
        "copying": "копирование",
        "checking tools": "проверка инструментов",
        "checking for a newer extract": "проверка обновления выгрузки",
        "verifying cached copy": "проверка копии из кэша",
        "cached copy was damaged — downloading again": "копия в кэше повреждена — повторная загрузка",
        "verifying checksum": "проверка контрольной суммы",
        "downloaded": "скачано",
        "all from the cache": "все из кэша",
        "all downloaded": "все скачаны",
        "%1$d downloaded, %2$d from the cache": "скачано %1$d, из кэша %2$d",
        "mkgmap's own rendering, no TYP — whatever your device defaults to":
            "отрисовка самого mkgmap, без TYP — как решит прибор",
        "somebody's front gate — the bulk of village clutter": "частные калитки — основной шум на карте в сёлах",
        "the drive itself is mapped as a road": "сам подъезд отмечен как дорога",
        "a gate here may be locked — usually worth keeping":
            "такая калитка может быть заперта — обычно её стоит оставить",
        "on major roads, or standing on no way at all": "на больших дорогах или вовсе не на дороге",
        "Place names": "Названия мест",
        "the labels of cities, towns and villages": "подписи городов, посёлков и сёл",
        "POIs": "Точки POI",
        "every point icon — shops, springs, peaks, bus stops":
            "все точечные значки — магазины, родники, вершины, остановки",
        "cpu %d%%": "цп %d%%",
        "GB": "ГБ",
        "Default": "По умолчанию",
        "Default, 4 levels": "По умолчанию, 4 уровня",
        "add / remove": "добавить / убрать",
        "as it comes": "как в стиле",
        "as it comes: %@": "в стиле: %@",
        "and stops at level %d": "и заканчивается на уровне %d",
        "a family has to be drawn somewhere — use Hide on map instead":
            "объект должен быть виден хотя бы на одном уровне — для полного отключения есть «Скрыть на карте»",
        "moved to %@ — the rows are back to what the style does":
            "переведён на %@ — строки вернулись к тому, что делает стиль",
        "Choose the zoom levels where each kind of feature is shown. Arrows move the cursor, space turns a level on or off; the range is always continuous.":
            "Выберите, на каких уровнях зума виден каждый вид объектов. Стрелки двигают курсор, пробел включает и выключает уровень; диапазон всегда сплошной.",
        "paths, tracks, footways, steps, via ferrata — what you walk":
            "тропы, грунтовки, дорожки, лестницы, виа феррата — то, по чему ходят",
        "everything a vehicle drives on, link roads and slip roads too":
            "всё, по чему едут, вместе со съездами и связками",
        "rivers, lakes, wetland, the coast and the sea": "реки, озёра, болота, берег и море",
        "Open ground": "Открытая земля",
        "cliffs, scree, bare rock, grassland, glacier, valleys, cutlines":
            "обрывы, осыпи, скалы, луга, ледники, долины, просеки",
        "Military land": "Военные земли",
        "ranges, danger areas, barracks and airfields — worth seeing early":
            "полигоны, опасные зоны, казармы и аэродромы — их лучше видеть заранее",
        "Settlements": "Населённые пункты",
        "villages, suburbs, squares and named islands, as ground":
            "сёла, районы, площади и именованные острова — как площадь",
        "car parks and their ground, as an area rather than a POI":
            "стоянки и их территория — как площадь, а не как точка",
        "farmland, industry, housing, shops, tourism — whatever is left":
            "пашня, промзона, застройка, магазины, туризм — всё остальное",
        "edit these on the Zoom plans screen": "меняется на экране «Планы зума»",
        "Plans marked · come with kmap and cannot be edited. Copy one, and the copy is yours to change.":
            "Планы с точкой встроены в kmap, их нельзя изменить. Скопируйте план — копию можно менять.",
        "⏎ to make another": "⏎ — создать ещё один",
        "300 m": "300 м",
        "600 m": "600 м",
        "1.2 km": "1,2 км",
        "3 km": "3 км",
        "5 km": "5 км",
        "Rail and cableways": "Рельсы и канатки",
        "Barriers": "Преграды",
        "fences, walls, gates and hedges — what stops you":
            "заборы, стены, ворота и живые изгороди — то, что преграждает путь",
        "Power lines": "ЛЭП",
        "transmission lines and their pylons: landmarks in open country":
            "линии электропередачи и опоры: ориентир на открытой местности",
        "runways, taxiways, aprons and airfield ground": "полосы, рулёжки, перроны и земля аэродрома",
        "Boundaries": "Границы",
        "administrative borders, which the device also draws itself":
            "административные границы, которые прибор рисует и сам",
        "Parking": "Парковки",
        "Sport and leisure": "Спорт и отдых",
        "pitches, tracks, playgrounds, parks and gardens": "площадки, дорожки, детские площадки, парки и сады",
        "the elevation lines and their labels": "линии высот и их подписи",
        "Trails and tracks": "Тропы и грунтовки",
        "Roads": "Дороги",
        "rail, tram, funicular and the aerialways": "железная дорога, трамвай, фуникулёр и канатки",
        "Water": "Вода",
        "Woodland": "Лес",
        "forest, wood and scrub — the fills that cover the most ground":
            "лес, роща и кустарник — заливки, покрывающие больше всего земли",
        "Protected land": "Охраняемые земли",
        "reserves, national parks and their outlines": "заповедники, национальные парки и их контуры",
        "Buildings": "Здания",
        "building outlines, which are many and small": "контуры зданий — их много и они мелкие",
        "%@ left": "осталось %@",
        "waiting for %@": "ждёт %@",
        "%@ is still installing": "%@ ещё устанавливается",
        "%@ is waiting to install": "%@ ожидает установки",
        "still installing: ^C stops everything": "установка идёт: ^C останавливает всё",
        "needs root, press Enter on its row: %@": "устанавливается от root, Enter на его строке: %@"
    ]

    /// Russian plural forms, by CLDR category: "one", "few", "many".
    private static let russianPlurals: [String: [String: String]] = [
        "%d free code(s) — ⏎ unfolds them": [
            "one": "%d свободный код — ⏎ развернёт",
            "few": "%d свободных кода — ⏎ развернёт",
            "many": "%d свободных кодов — ⏎ развернёт"
        ],
        "%2$@ is emitted by %1$d rule(s):": [
            "one": "%2$@ выдаёт %1$d правило:",
            "few": "%2$@ выдают %1$d правила:",
            "many": "%2$@ выдают %1$d правил:"
        ],
        "%2$@ replaces %1$d marked inside it": [
            "one": "%2$@ заменяет %1$d отмеченный внутри",
            "few": "%2$@ заменяет %1$d отмеченных внутри",
            "many": "%2$@ заменяет %1$d отмеченных внутри"
        ],
        "%d colour(s)": [
            "one": "%d цвет",
            "few": "%d цвета",
            "many": "%d цветов"
        ],
        "%d archive(s) to fetch, of a size the server did not report": [
            "one": "%d архив к загрузке, размер сервер не сообщил",
            "few": "%d архива к загрузке, размер сервер не сообщил",
            "many": "%d архивов к загрузке, размер сервер не сообщил"
        ],
        "the %d cell(s) left are open sea or unsurveyed — nothing to fetch": [
            "one": "оставшаяся %d ячейка — открытое море или вне съёмки, загружать нечего",
            "few": "оставшиеся %d ячейки — открытое море или вне съёмки, загружать нечего",
            "many": "оставшиеся %d ячеек — открытое море или вне съёмки, загружать нечего"
        ],
        "elevation: %d cell(s) after the outline trim": [
            "one": "высоты: %d ячейка после обрезки по контуру",
            "few": "высоты: %d ячейки после обрезки по контуру",
            "many": "высоты: %d ячеек после обрезки по контуру"
        ],
        "%d cell(s), unmeasured": [
            "one": "%d ячейка, без замера",
            "few": "%d ячейки, без замера",
            "many": "%d ячеек, без замера"
        ],
        "%d zone archive(s)": [
            "one": "%d архив зоны",
            "few": "%d архива зон",
            "many": "%d архивов зон"
        ],
        "measured on %d tile(s)": [
            "one": "измерено на %d плитке",
            "few": "измерено на %d плитках",
            "many": "измерено на %d плитках"
        ],
        "%d entries": [
            "one": "%d запись",
            "few": "%d записи",
            "many": "%d записей"
        ],
        "%d extract(s)": [
            "one": "%d выгрузка",
            "few": "%d выгрузки",
            "many": "%d выгрузок"
        ],
        "%d fall back to the device": [
            "one": "%d тип рисует сам прибор",
            "few": "%d типа рисует сам прибор",
            "many": "%d типов рисует сам прибор"
        ],
        "%d feature(s)": [
            "one": "%d объект",
            "few": "%d объекта",
            "many": "%d объектов"
        ],
        "%d feature(s) left off the map": [
            "one": "%d объект убран с карты",
            "few": "%d объекта убраны с карты",
            "many": "%d объектов убраны с карты"
        ],
        "%d file(s)": [
            "one": "%d файл",
            "few": "%d файла",
            "many": "%d файлов"
        ],
        "%d element(s)": [
            "one": "%d элемент",
            "few": "%d элемента",
            "many": "%d элементов"
        ],
        "%d code(s) in this map": [
            "one": "%d код в этой карте",
            "few": "%d кода в этой карте",
            "many": "%d кодов в этой карте"
        ],
        "%d understood": [
            "one": "%d разобран",
            "few": "%d разобрано",
            "many": "%d разобрано"
        ],
        "%d code(s) left alone — no rule of ours is aimed at them, so the map goes on drawing them as it did:": [
            "one": "%d код оставлен как есть — наши правила его не затрагивают, карта рисует его по-прежнему:",
            "few": "%d кода оставлены как есть — наши правила их не затрагивают, карта рисует их по-прежнему:",
            "many": "%d кодов оставлены как есть — наши правила их не затрагивают, карта рисует их по-прежнему:"
        ],
        "deleted %2$@ — %1$d profile(s) now build with %3$@": [
            "one": "удалён %2$@ — на %3$@ перешёл %1$d профиль",
            "few": "удалён %2$@ — на %3$@ перешли %1$d профиля",
            "many": "удалён %2$@ — на %3$@ перешли %1$d профилей"
        ],
        "and %d more": [
            "one": "и ещё %d",
            "few": "и ещё %d",
            "many": "и ещё %d"
        ],
        "%d file(s) of equal weight, whatever that means for the card": [
            "one": "%d файл равного размера, независимо от ёмкости карты памяти",
            "few": "%d файла равного размера, независимо от ёмкости карты памяти",
            "many": "%d файлов равного размера, независимо от ёмкости карты памяти"
        ],
        "%d hidden": [
            "one": "%d скрыт",
            "few": "%d скрыто",
            "many": "%d скрыто"
        ],
        "%d known code(s)": [
            "one": "%d известный код",
            "few": "%d известных кода",
            "many": "%d известных кодов"
        ],
        "%d left to it on purpose": [
            "one": "%d оставлен ему намеренно",
            "few": "%d оставлено ему намеренно",
            "many": "%d оставлено ему намеренно"
        ],
        "%d map(s)": [
            "one": "%d карта",
            "few": "%d карты",
            "many": "%d карт"
        ],
        "%d marked": [
            "one": "%d отмечен",
            "few": "%d отмечено",
            "many": "%d отмечено"
        ],
        "%d meanings": [
            "one": "%d значение",
            "few": "%d значения",
            "many": "%d значений"
        ],
        "%d not fully decoded — marked in the file": [
            "one": "%d не декодирован до конца — отмечено в файле",
            "few": "%d не декодированы до конца — отмечено в файле",
            "many": "%d не декодировано до конца — отмечено в файле"
        ],
        "%d region(s)": [
            "one": "%d регион",
            "few": "%d региона",
            "many": "%d регионов"
        ],
        "%d elevation cell(s) beyond the region's outline have no data — the relief there reads as sea level, and so does the map":
            [
                "one":
                    "%d ячейка рельефа за контуром региона без данных — рельеф там читается как уровень моря, и карта там пуста",
                "few":
                    "%d ячейки рельефа за контуром региона без данных — рельеф там читается как уровень моря, и карта там пуста",
                "many":
                    "%d ячеек рельефа за контуром региона без данных — рельеф там читается как уровень моря, и карта там пуста"
            ],
        "%d section(s)": [
            "one": "%d секция",
            "few": "%d секции",
            "many": "%d секций"
        ],
        "%d style(s)": [
            "one": "%d стиль",
            "few": "%d стиля",
            "many": "%d стилей"
        ],
        "%d styled but never emitted": [
            "one": "%d оформлен, но никогда не выдаётся",
            "few": "%d оформлены, но никогда не выдаются",
            "many": "%d оформлено, но никогда не выдаётся"
        ],
        "%d sub-region(s)": [
            "one": "%d вложенный регион",
            "few": "%d вложенных региона",
            "many": "%d вложенных регионов"
        ],
        "%d tile(s)": [
            "one": "%d плитка",
            "few": "%d плитки",
            "many": "%d плиток"
        ],
        "%d × 1° tile(s)": [
            "one": "%d плитка 1°",
            "few": "%d плитки 1°",
            "many": "%d плиток 1°"
        ],
        "cleared %d extract(s), %@": [
            "one": "очищена %d выгрузка, %@",
            "few": "очищено %d выгрузки, %@",
            "many": "очищено %d выгрузок, %@"
        ],
        "cleared %d tile(s), %@": [
            "one": "очищена %d плитка, %@",
            "few": "очищено %d плитки, %@",
            "many": "очищено %d плиток, %@"
        ],
        "decompiled %d element(s)": [
            "one": "декомпилирован %d элемент",
            "few": "декомпилировано %d элемента",
            "many": "декомпилировано %d элементов"
        ],

        "%d family(ies) moved": [
            "one": "сдвинуто %d семейство",
            "few": "сдвинуто %d семейства",
            "many": "сдвинуто %d семейств"
        ],
        "%d rule(s) in the style": [
            "one": "%d правило в стиле",
            "few": "%d правила в стиле",
            "many": "%d правил в стиле"
        ]
    ]

    // MARK: - English
    //
    // Counted strings only; every other key is its own English text.

    private static let englishPlurals: [String: [String: String]] = [
        "%d free code(s) — ⏎ unfolds them": [
            "one": "%d free code — ⏎ unfolds it",
            "other": "%d free codes — ⏎ unfolds them"
        ],
        "%2$@ is emitted by %1$d rule(s):": [
            "one": "%2$@ is emitted by %1$d rule:",
            "other": "%2$@ is emitted by %1$d rules:"
        ],
        "%2$@ replaces %1$d marked inside it": [
            "one": "%2$@ replaces %1$d marked inside it",
            "other": "%2$@ replaces %1$d marked inside it"
        ],
        "%d colour(s)": [
            "one": "%d colour",
            "other": "%d colours"
        ],
        "%d element(s)": [
            "one": "%d element",
            "other": "%d elements"
        ],
        "%d code(s) in this map": [
            "one": "%d code in this map",
            "other": "%d codes in this map"
        ],
        "%d understood": [
            "one": "%d understood",
            "other": "%d understood"
        ],
        "%d code(s) left alone — no rule of ours is aimed at them, so the map goes on drawing them as it did:": [
            "one": "%d code left alone — no rule of ours is aimed at it, so the map goes on drawing it as it did:",
            "other":
                "%d codes left alone — no rule of ours is aimed at them, so the map goes on drawing them as it did:"
        ],
        "deleted %2$@ — %1$d profile(s) now build with %3$@": [
            "one": "deleted %2$@ — %1$d profile now builds with %3$@",
            "other": "deleted %2$@ — %1$d profiles now build with %3$@"
        ],
        "and %d more": [
            "one": "and %d more",
            "other": "and %d more"
        ],
        "%d archive(s) to fetch, of a size the server did not report": [
            "one": "%d archive to fetch, of a size the server did not report",
            "other": "%d archives to fetch, of a size the server did not report"
        ],
        "the %d cell(s) left are open sea or unsurveyed — nothing to fetch": [
            "one": "the %d cell left is open sea or unsurveyed — nothing to fetch",
            "other": "the %d cells left are open sea or unsurveyed — nothing to fetch"
        ],
        "elevation: %d cell(s) after the outline trim": [
            "one": "elevation: %d cell after the outline trim",
            "other": "elevation: %d cells after the outline trim"
        ],
        "%d cell(s), unmeasured": [
            "one": "%d cell, unmeasured",
            "other": "%d cells, unmeasured"
        ],
        "%d zone archive(s)": [
            "one": "%d zone archive",
            "other": "%d zone archives"
        ],
        "measured on %d tile(s)": [
            "one": "measured on %d tile",
            "other": "measured on %d tiles"
        ],
        "%d entries": [
            "one": "%d entry",
            "other": "%d entries"
        ],
        "%d extract(s)": [
            "one": "%d extract",
            "other": "%d extracts"
        ],
        "%d fall back to the device": [
            "one": "%d falls back to the device",
            "other": "%d fall back to the device"
        ],
        "%d feature(s)": [
            "one": "%d feature",
            "other": "%d features"
        ],
        "%d feature(s) left off the map": [
            "one": "%d feature left off the map",
            "other": "%d features left off the map"
        ],
        "%d file(s)": [
            "one": "%d file",
            "other": "%d files"
        ],
        "%d file(s) of equal weight, whatever that means for the card": [
            "one": "%d file of equal weight, whatever that means for the card",
            "other": "%d files of equal weight, whatever that means for the card"
        ],
        "%d hidden": [
            "one": "%d hidden",
            "other": "%d hidden"
        ],
        "%d known code(s)": [
            "one": "%d known code",
            "other": "%d known codes"
        ],
        "%d left to it on purpose": [
            "one": "%d left to it on purpose",
            "other": "%d left to it on purpose"
        ],
        "%d map(s)": [
            "one": "%d map",
            "other": "%d maps"
        ],
        "%d marked": [
            "one": "%d marked",
            "other": "%d marked"
        ],
        "%d meanings": [
            "one": "%d meaning",
            "other": "%d meanings"
        ],
        "%d not fully decoded — marked in the file": [
            "one": "%d not fully decoded — marked in the file",
            "other": "%d not fully decoded — marked in the file"
        ],
        "%d region(s)": [
            "one": "%d region",
            "other": "%d regions"
        ],
        "%d elevation cell(s) beyond the region's outline have no data — the relief there reads as sea level, and so does the map":
            [
                "one":
                    "%d elevation cell beyond the region's outline has no data — the relief there reads as sea level, and so does the map",
                "other":
                    "%d elevation cells beyond the region's outline have no data — the relief there reads as sea level, and so does the map"
            ],
        "%d section(s)": [
            "one": "%d section",
            "other": "%d sections"
        ],
        "%d style(s)": [
            "one": "%d style",
            "other": "%d styles"
        ],
        "%d styled but never emitted": [
            "one": "%d styled but never emitted",
            "other": "%d styled but never emitted"
        ],
        "%d sub-region(s)": [
            "one": "%d sub-region",
            "other": "%d sub-regions"
        ],
        "%d tile(s)": [
            "one": "%d tile",
            "other": "%d tiles"
        ],
        "%d family(ies) moved": [
            "one": "%d family moved",
            "other": "%d families moved"
        ],
        "%d rule(s) in the style": [
            "one": "%d rule in the style",
            "other": "%d rules in the style"
        ],
        "%d × 1° tile(s)": [
            "one": "%d × 1° tile",
            "other": "%d × 1° tiles"
        ],
        "cleared %d extract(s), %@": [
            "one": "cleared %d extract, %@",
            "other": "cleared %d extracts, %@"
        ],
        "cleared %d tile(s), %@": [
            "one": "cleared %d tile, %@",
            "other": "cleared %d tiles, %@"
        ],
        "decompiled %d element(s)": [
            "one": "decompiled %d element",
            "other": "decompiled %d elements"
        ]
    ]
}
