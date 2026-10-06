import Foundation

/// Пункт меню выбора модели; `model == nil` — «Модель CLI».
struct ModelMenuItem: Equatable, Identifiable {
    let title: String
    let model: String?

    var id: String { model ?? "" }

    static let defaultItem = ModelMenuItem(title: ModelName.defaultTitle, model: nil)

    init(model: String?) {
        self.model = model
        self.title = model.map(ModelName.short) ?? ModelName.defaultTitle
    }

    private init(title: String, model: String?) {
        self.title = title
        self.model = model
    }
}

/// Группы пунктов меню: между группами — разделитель. Пустых групп нет.
typealias ModelMenuSections = [[ModelMenuItem]]

enum ModelMenu {
    /// Панель ввода: «Модель CLI», затем список моделей исполнителя.
    static func inputSections(models: [String]) -> ModelMenuSections {
        sections([ModelMenuItem.defaultItem], models.map { ModelMenuItem(model: $0) })
    }

    fileprivate static func sections(_ groups: [ModelMenuItem]...) -> ModelMenuSections {
        groups.filter { !$0.isEmpty }
    }
}

/// Выбор модели для уточнения в карточке диалога.
///
/// Уточнение без смены модели ядро всё равно ведёт на модели точки продолжения, поэтому «базой»
/// служит она, а не «Модель CLI»: у диалога с известной моделью такого пункта в меню нет.
/// Модель точки — `continuationPoint.model`, а не последней задачи диалога: после неудачного
/// уточнения на другой модели они различаются, а ядро продолжит ту, на которой остановилась сессия.
struct FollowUpModelChoice: Equatable {
    /// Модель точки продолжения; нет — у диалога нет известной модели (история до выбора моделей).
    let pointModel: String?
    /// Выбор пользователя; nil — не менял.
    let selection: String?

    init(pointModel: String?, selection: String?) {
        self.pointModel = pointModel.flatMap { $0.isEmpty ? nil : $0 }
        self.selection = selection
    }

    /// Показываемая модель; nil — «Модель CLI».
    var shown: String? { selection ?? pointModel }

    /// `TaskSubmitParams.model`: только выбранная и отличная от модели точки, иначе поля нет.
    var requestModel: String? {
        guard let selection, selection != pointModel else { return nil }
        return selection
    }

    /// Подпись элемента: «Claude Code · <короткое имя>».
    var label: String {
        "Claude Code · \(shown.map(ModelName.short) ?? ModelName.defaultTitle)"
    }

    /// Диалог с моделью: она сама первым пунктом, затем список. Без модели — «Модель CLI» и список.
    func sections(models: [String]) -> ModelMenuSections {
        let list = models.filter { $0 != pointModel }.map { ModelMenuItem(model: $0) }
        if let pointModel { return ModelMenu.sections([ModelMenuItem(model: pointModel)], list) }
        return ModelMenu.sections([ModelMenuItem.defaultItem], list)
    }
}

extension Dialog {
    /// Модель для шапки окна диалога: короткое имя модели последней задачи; у задачи без модели — nil.
    var modelTitle: String? {
        guard let model = last.model, !model.isEmpty else { return nil }
        return ModelName.short(model)
    }
}
