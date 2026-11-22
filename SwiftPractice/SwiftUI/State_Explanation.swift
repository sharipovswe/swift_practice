// ============================================================================
// State_Explanation.swift
// @State — локальное состояние SwiftUI-представления
// Уровень: Senior / Lead iOS Engineer
// ============================================================================
//
// СОДЕРЖАНИЕ
//  1. Теория: View как функция состояния, source of truth
//  2. Как работает @State под капотом
//  3. Сценарии: примитивы, struct, enum-состояние, Binding, sheet, анимации
//  4. @State + @Observable (iOS 17+): владение моделью
//  5. Production-пример: форма с валидацией и ViewState
//  6. Архитектурный анализ, ошибки, best practices
//  7. Связь с @Observable, @Bindable, Clean Architecture, concurrency
//
// ВАЖНО про имена: в main.swift объявлен класс `View`. Внутри одного модуля
// он затеняет SwiftUI.View, поэтому здесь везде пишем `SwiftUI.View`.
// Типы лежат в неймспейсе `StateLesson`.
// ============================================================================

import SwiftUI

enum StateLesson {

    // ========================================================================
    // 1. ТЕОРИЯ
    // ========================================================================
    //
    // SwiftUI декларативен: UI = f(state). Вы описываете, КАК выглядит экран
    // при данном состоянии; фреймворк сам вычисляет разницу и обновляет.
    //
    // View — это struct (value type), дешёвая и недолговечная: SwiftUI
    // пересоздаёт её при каждом изменении зависимостей. Значит хранить
    // изменяемые данные в обычном `var` внутри View НЕЛЬЗЯ — они сбросятся
    // при пересоздании.
    //
    // @State — способ сказать SwiftUI: "это значение хранится ВНЕ структуры
    // (в памяти, управляемой фреймворком для данной позиции View в иерархии);
    // при его изменении пересчитай body".
    //
    // SOURCE OF TRUTH (единый источник правды): у каждого значения есть
    // ровно ОДИН владелец. @State = владение.
    //   @State       — View владеет значением (создаёт и хранит)
    //   @Binding     — View читает/пишет значение, которым владеет ДРУГОЙ
    //   let / var    — View получила значение только для чтения
    //   @Environment — значение из окружения
    //
    // Пара правил Apple:
    //  - @State помечай `private`: это внутренняя деталь View
    //  - храни в @State "лёгкое" локальное UI-состояние (раскрыт ли список,
    //    текст поля, выбранная вкладка), а не бизнес-данные

    // ========================================================================
    // 2. ПОД КАПОТОМ
    // ========================================================================
    //
    // @State — property wrapper (struct State<Value>). Он:
    //  - хранит значение в "ящике" (storage), прикреплённом к идентичности
    //    View в графе (а не к конкретному экземпляру struct)
    //  - при записи (set) помечает граф зависимостей "грязным" -> SwiftUI
    //    заново вызывает body у зависимых View
    //  - wrappedValue = само значение, projectedValue ($name) = Binding<Value>
    //
    // Идентичность: если View пересоздаётся на том же месте с тем же
    // структурным/явным id, @State СОХРАНЯЕТСЯ. Если View удалена из
    // иерархии (if/else ветка, смена .id()), состояние УНИЧТОЖАЕТСЯ.
    //
    // Инициализатор вида `@State private var x = 0` выполняется при каждом
    // создании структуры, но SwiftUI использует только ПЕРВОЕ значение —
    // поэтому тяжёлую инициализацию в initial value класть не стоит.

    // ========================================================================
    // 3. СЦЕНАРИИ
    // ========================================================================

    // ------------------------------------------------------------------------
    // Сценарий A. Простейший: примитив + $binding
    // ------------------------------------------------------------------------
    struct CounterView: SwiftUI.View {
        // Владение значением. private — деталь реализации.
        @State private var count = 0

        var body: some SwiftUI.View {
            VStack(spacing: 12) {
                Text("Счётчик: \(count)")
                // Запись в @State вызывает перерисовку
                Button("Плюс") { count += 1 }
                // $count — Binding<Int>: «ручка» для чтения/записи извне
                Stepper("Шаг", value: $count, in: 0...10)
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий B. @State + @Binding: родитель владеет, ребёнок меняет.
    // ------------------------------------------------------------------------
    // Ребёнок не знает, ОТКУДА значение (State, поле модели, constant) —
    // это развязка и переиспользуемость (SRP/ISP).

    struct ToggleRow: SwiftUI.View {
        let title: String
        @Binding var isOn: Bool                       // не владеем, только ссылаемся

        var body: some SwiftUI.View {
            Toggle(title, isOn: $isOn)
        }
    }

    struct SettingsView: SwiftUI.View {
        @State private var notifications = true
        @State private var darkMode = false

        var body: some SwiftUI.View {
            Form {
                ToggleRow(title: "Уведомления", isOn: $notifications)   // передаём Binding
                ToggleRow(title: "Тёмная тема", isOn: $darkMode)
                Text(notifications ? "Включены" : "Выключены")
            }
        }
    }

    // Превью/тесты: Binding без владельца
    //   ToggleRow(title: "X", isOn: .constant(true))

    // ------------------------------------------------------------------------
    // Сценарий C. Struct и enum в @State: состояние экрана как ОДНО значение.
    // ------------------------------------------------------------------------
    // Вместо пяти булевых флагов — enum: невозможные состояния невыразимы.

    enum LoadPhase: Equatable {
        case idle, loading, loaded([String]), failed(String)
    }

    struct PhaseView: SwiftUI.View {
        @State private var phase: LoadPhase = .idle

        var body: some SwiftUI.View {
            switch phase {
            case .idle:            Button("Загрузить") { Task { await load() } }
            case .loading:         ProgressView()
            case .loaded(let xs):  List(xs, id: \.self) { Text($0) }
            case .failed(let m):   Text(m).foregroundStyle(.red)
            }
        }

        // Метод View мутирует @State — это безопасно: @State-хранилище
        // ссылочное, поэтому методы не обязаны быть `mutating`.
        @MainActor private func load() async {
            phase = .loading
            try? await Task.sleep(for: .milliseconds(300))
            phase = .loaded(["А", "Б"])
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий D. Локальные UI-состояния: sheet, alert, focus, анимация.
    // ------------------------------------------------------------------------
    struct SheetItem: Identifiable { let id: String }

    struct PresentationView: SwiftUI.View {
        @State private var showSheet = false
        @State private var selectedItem: SheetItem?       // item-based sheet (нужен Identifiable)
        @State private var expanded = false
        @FocusState private var focused: Bool             // родственник @State для фокуса
        @State private var text = ""

        var body: some SwiftUI.View {
            VStack {
                Button("Показать sheet") { showSheet = true }
                    .sheet(isPresented: $showSheet) { Text("Sheet") }

                // item-sheet: показывается, когда selectedItem != nil
                Button("Item") { selectedItem = SheetItem(id: "A") }
                    .sheet(item: $selectedItem) { Text($0.id) }

                // withAnimation: изменение @State внутри блока анимируется
                Button("Раскрыть") { withAnimation(.spring) { expanded.toggle() } }
                if expanded { Text("Подробности").transition(.opacity) }

                TextField("Текст", text: $text).focused($focused)
            }
        }
    }

    // ------------------------------------------------------------------------
    // Сценарий E. Параметризация: начальное значение из init.
    // ------------------------------------------------------------------------
    // @State нельзя "обновить" из внешнего параметра после создания — он
    // инициализируется ОДИН РАЗ. Если нужен ПОСТОЯННЫЙ вход из родителя —
    // это let/@Binding, а не @State.

    struct EditorView: SwiftUI.View {
        @State private var draft: String

        init(initialText: String) {
            // Явная инициализация обёртки через _name
            _draft = State(initialValue: initialText)
        }
        var body: some SwiftUI.View { TextField("Черновик", text: $draft) }
    }

    // ========================================================================
    // 4. @State + @Observable (iOS 17+)
    // ========================================================================
    //
    // С Observation @State получил вторую роль: ВЛАДЕНИЕ ссылочной моделью.
    // Заменяет @StateObject:
    //
    //   iOS 13–16:  @StateObject var vm = ViewModel()   // ObservableObject
    //   iOS 17+  :  @State var vm = ViewModel()          // @Observable
    //
    // @State гарантирует, что экземпляр модели создан один раз и живёт
    // столько же, сколько View в иерархии (не пересоздаётся при каждом
    // body родителя). Подробнее — Observable_Explanation, Bindable_Explanation.

    @Observable
    final class TimerModel {
        var seconds = 0
        func tick() { seconds += 1 }
    }

    struct TimerView: SwiftUI.View {
        @State private var model = TimerModel()       // View ВЛАДЕЕТ моделью
        var body: some SwiftUI.View {
            Button("Секунд: \(model.seconds)") { model.tick() }
        }
    }

    // ========================================================================
    // 5. PRODUCTION-ПРИМЕР: форма регистрации с валидацией
    // ========================================================================
    //
    // Что в @State: чисто UI-состояние формы (ввод, фокус, показ ошибок).
    // Что НЕ в @State: отправка на сервер, бизнес-правила — они в ViewModel/
    // UseCase. View отображает состояние и передаёт намерения (intents).

    struct SignUpForm: Equatable {
        var email = ""
        var password = ""
        var agreed = false

        // Вычисляемое — всегда согласовано с полями (нет рассинхрона)
        var emailError: String? {
            email.isEmpty || email.contains("@") ? nil : "Некорректный email"
        }
        var passwordError: String? {
            password.isEmpty || password.count >= 8 ? nil : "Минимум 8 символов"
        }
        var canSubmit: Bool {
            !email.isEmpty && emailError == nil && passwordError == nil && agreed
        }
    }

    struct SignUpView: SwiftUI.View {
        // ОДИН @State с struct вместо трёх — атомарные изменения, легко
        // тестировать SignUpForm отдельно от UI.
        @State private var form = SignUpForm()
        @State private var isSubmitting = false

        // Зависимость как замыкание: View не знает о сети (DIP).
        let submit: (SignUpForm) async -> Void

        var body: some SwiftUI.View {
            Form {
                TextField("Email", text: $form.email)         // $form.email — Binding на поле struct
                if let e = form.emailError { Text(e).foregroundStyle(.red) }

                SecureField("Пароль", text: $form.password)
                if let e = form.passwordError { Text(e).foregroundStyle(.red) }

                Toggle("Согласен с условиями", isOn: $form.agreed)

                Button(isSubmitting ? "Отправка…" : "Создать аккаунт") {
                    Task {
                        isSubmitting = true
                        await submit(form)
                        isSubmitting = false
                    }
                }
                .disabled(!form.canSubmit || isSubmitting)
            }
        }
    }

    // ========================================================================
    // 6. АРХИТЕКТУРНЫЙ АНАЛИЗ, ОШИБКИ, BEST PRACTICES
    // ========================================================================
    //
    // ИСПОЛЬЗУЙ @State для:
    //  - эфемерного UI-состояния конкретного View (toggle, sheet, текст, фокус)
    //  - ВЛАДЕНИЯ @Observable-моделью, жизненный цикл которой = жизни View
    //  - значений, нужных только для анимаций/жестов
    //
    // НЕ ИСПОЛЬЗУЙ @State для:
    //  - данных, которые нужны нескольким экранам -> модель выше по иерархии /
    //    @Environment / DI
    //  - бизнес-состояния и результатов сети -> ViewModel
    //  - значений, приходящих из родителя -> let / @Binding
    //  - тяжёлых вычислений в initial value
    //
    // ПЛЮСЫ: просто, локально, автоматические обновления, value semantics.
    // МИНУСЫ: умирает вместе с View, не шарится, не переживает пересоздание
    //   identity, сложнее тестировать логику внутри View.
    //
    // ОШИБКИ:
    //  1. Не private + передача `State` в дочерние вместо Binding.
    //  2. Ожидание, что @State обновится при смене параметра родителя.
    //  3. Класс (ObservableObject/обычный) в @State без @Observable —
    //     изменения полей НЕ вызовут перерисовку.
    //  4. Запись в @State прямо во время вычисления body -> бесконечный цикл.
    //  5. Сброс состояния из-за нестабильной identity (.id(UUID()) в body,
    //     if/else, подменяющие View).
    //  6. Хранение бизнес-логики/сети в самой View.
    //  7. Много мелких @State, меняющихся вместе -> объедини в struct.
    //  8. Запись из фонового потока (в Swift 6 View.body на @MainActor).
    //
    // BEST PRACTICES:
    //  - минимальный набор состояния; всё производное — computed property
    //  - состояние экрана = enum/struct, а не набор флагов
    //  - `$` передавай вниз как Binding, значение — как let
    //  - логика в ViewModel/UseCase; View — отображение + intents
    //  - превью с .constant и тестовыми моделями

    // ========================================================================
    // 7. СВЯЗЬ С ДРУГИМИ МЕХАНИЗМАМИ
    // ========================================================================
    //  @Observable: ссылочная модель; @State ею владеет (Observable_Explanation).
    //  @Bindable:   даёт $-биндинги к свойствам @Observable-объекта, которым
    //               вы НЕ владеете (Bindable_Explanation).
    //  Clean Architecture: @State — слой Presentation, UI-детали; бизнес в Domain.
    //  Concurrency: View.body и @State изолированы на @MainActor; асинхронную
    //               работу запускай в `.task { }` (отмена при уходе View) или
    //               Task из метода; результат записывай на main.
    //  SOLID: View зависит от замыкания/протокола, а не от конкретной сети.
}
