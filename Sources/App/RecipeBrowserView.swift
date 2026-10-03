import SwiftUI
import AppKit
import Recipes
import RecipeUI
import StudioTheme
import Catalog
import RawDecode

struct RecipeAttributionView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var recipes: RecipeBrowserModel
    var body: some View {
        if editor.canUseCamera && !editor.libraryMode {
            if recipes.hasBookmark && (recipes.isLoading || !recipes.canSave) {
                HStack(spacing: 8) {
                    Text(recipes.message).foregroundStyle(Studio.warning)
                    StudioButton("Recipes") { editor.showsRecipes = true }
                }.font(StudioFont.caption()).lineLimit(1).truncationMode(.tail).padding(8)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            }
            if let attribution = editor.recipeAttribution(in: recipes.recipes) {
                Text(attribution).font(StudioFont.caption()).foregroundStyle(Studio.warning)
                    .lineLimit(1).truncationMode(.tail).padding(8)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            }
        }
    }
}

struct RecipeBrowserView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var model: RecipeBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var draft: Recipe?
    @State private var failure: String?
    private var selected: Recipe? { model.recipes.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Recipes").font(StudioFont.headline()).foregroundStyle(Studio.accent)
                Spacer()
                StudioButton("Choose spreadsheet", icon: .folder) { editor.chooseRecipeSpreadsheet() }
                    .disabled(model.isSaving)
                StudioButton("Reload") { Task { await model.reload() } }.disabled(model.isSaving || !model.hasBookmark)
                StudioButton("Close") { dismiss() }
            }
            Text(model.message).foregroundStyle(Studio.warning).textSelection(.enabled)
            if let failure { Text(failure).foregroundStyle(Studio.warning).textSelection(.enabled) }
            RecipeAttributionView(editor: editor, recipes: model)
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.recipes) { recipe in
                            Button { selectedID = recipe.id; failure = nil } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(recipe.name).foregroundStyle(Studio.textPrimary)
                                    Text(recipe[.filmSimulation]).foregroundStyle(Studio.accent)
                                    RecipeWarningsView(warnings: recipe.warnings)
                                }
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .studioSurface(fill: Studio.groupedPanel)
                                .studioSelected(selectedID == recipe.id)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 256)
                ScrollView {
                    if let recipe = selected {
                        VStack(alignment: .leading, spacing: 16) {
                            StudioSection(recipe.name) {
                                ForEach(RecipeField.allCases.filter { !Recipe.exampleFields.contains($0) && !recipe[$0].isEmpty }, id: \.self) { field in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(field.rawValue.replacingOccurrences(of: "_", with: " ")).foregroundStyle(Studio.textSecondary)
                                            .frame(width: 160, alignment: .leading)
                                        Text(recipe[field]).textSelection(.enabled)
                                    }
                                }
                                RecipeWarningsView(warnings: recipe.warnings)
                            }
                            ForEach(Recipe.exampleFields.filter { !recipe[$0].isEmpty }, id: \.self) { field in
                                RecipeExampleView(model: model, filename: recipe[field],
                                    warnings: recipe.warnings.filter { $0.field == field.rawValue })
                                    .id("\(recipe.id):\(field.rawValue):\(recipe[field]):\(model.message)")
                            }
                            HStack(spacing: 8) {
                                StudioButton(editor.libraryMode ? "Apply to selection" : "Apply to current image", style: .prominent) {
                                    do { try editor.applyRecipe(recipe); failure = nil; editor.showsRecipes = false }
                                    catch { failure = "Could not apply recipe: \(error). Check its settings and import a matching camera profile." }
                                }.disabled(!editor.canApplyRecipe || !recipe.validationWarnings().isEmpty || !model.canSave)
                                .help(editor.canApplyRecipe ? "Apply recipe" : CameraSource.recipeHelp)
                                StudioButton("Edit recipe") { draft = recipe }.disabled(!model.canSave)
                            }
                        }
                    } else {
                        Text("Select a recipe to see settings, warnings and example photos.")
                            .foregroundStyle(Studio.textSecondary).padding(16)
                    }
                }
            }
            StudioButton("New recipe", icon: .settings) {
                draft = Recipe(fields: [.recipeID: UUID().uuidString, .name: "", .filmSimulation: Recipe.filmSimulations[0]])
            }.disabled(!model.canSave)
        }
        .font(StudioFont.caption()).foregroundStyle(Studio.textPrimary)
        .padding(16).frame(width: 960, height: 704).background(Studio.background)
        .sheet(item: $draft) { recipe in RecipeFormView(model: model, recipe: recipe) }
    }
}

private struct RecipeWarningsView: View {
    let warnings: [RecipeWarning]
    var body: some View {
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Text("Warning · row \(warning.row) · \(warning.field): \(warning.message)")
                .foregroundStyle(Studio.warning).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RecipeExampleView: View {
    @ObservedObject var model: RecipeBrowserModel
    let filename: String
    let warnings: [RecipeWarning]
    @State private var image: NSImage?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 192)
            } else {
                VStack(spacing: 8) {
                    Image(.image)
                    Text(failure ?? "Loading example…")
                }.frame(maxWidth: .infinity).frame(height: 128).studioSurface(fill: Studio.sunken)
            }
            Text(filename)
            RecipeWarningsView(warnings: warnings)
        }
        .task {
            do {
                let url = try await model.thumbnail(filename)
                guard let decoded = NSImage(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
                image = decoded
            } catch {
                failure = "Example unavailable: \(filename). Download it in Finder and check the examples folder. \(error.localizedDescription)"
            }
        }
    }
}

private struct RecipeFormView: View {
    @ObservedObject var model: RecipeBrowserModel
    @Environment(\.dismiss) private var dismiss
    @State var recipe: Recipe
    private var warnings: [RecipeWarning] { recipe.validationWarnings() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recipe settings").font(StudioFont.headline()).foregroundStyle(Studio.accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(RecipeField.allCases, id: \.self) { field in
                        HStack(alignment: .top, spacing: 8) {
                            Text(field.rawValue.replacingOccurrences(of: "_", with: " "))
                                .frame(width: 160, alignment: .leading).foregroundStyle(Studio.textSecondary)
                            input(field)
                        }
                    }
                    RecipeWarningsView(warnings: warnings)
                }.padding(8)
            }
            Text(model.message).foregroundStyle(Studio.warning)
            HStack(spacing: 8) {
                StudioButton("Save recipe", style: .prominent) {
                    Task { if await model.save(recipe) { dismiss() } }
                }.disabled(!warnings.isEmpty || !model.canSave)
                StudioButton("Cancel") { dismiss() }.disabled(model.isSaving)
            }
        }.font(StudioFont.caption()).foregroundStyle(Studio.textPrimary)
            .padding(16).frame(width: 640, height: 688).background(Studio.background)
            .interactiveDismissDisabled(model.isSaving)
    }

    private func binding(_ field: RecipeField) -> Binding<String> {
        Binding(get: { recipe[field] }, set: { recipe[field] = $0 })
    }

    @ViewBuilder private func input(_ field: RecipeField) -> some View {
        if field == .recipeID {
            // Stable identity is essential: changing it would append instead of editing the selected row.
            Text(recipe.id).textSelection(.enabled)
        } else if field == .filmSimulation {
            choices(field, values: Recipe.filmSimulations)
        } else if let constraint = Recipe.choiceConstraints.first(where: { $0.0 == field }) {
            choices(field, values: [""] + constraint.1)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: binding(field), axis: .vertical)
                    .textFieldStyle(.plain).padding(8).studioSurface(fill: Studio.sunken)
                if let (_, range, step) = Recipe.numericConstraints.first(where: { $0.0 == field }) {
                    HStack(spacing: 8) {
                        StudioButton("−") { stepValue(field, range: range, step: -step) }
                        StudioButton("+") { stepValue(field, range: range, step: step) }
                        Text("\(range.lowerBound.formatted())…\(range.upperBound.formatted()), step \(step.formatted()); blank allowed")
                            .foregroundStyle(Studio.textSecondary)
                    }
                }
            }
            // Text entry preserves invalid imported values for repair; the shared validator gates Save.
        }
    }

    private func stepValue(_ field: RecipeField, range: ClosedRange<Double>, step: Double) {
        let value = recipe.number(field) ?? max(range.lowerBound, min(range.upperBound, 0))
        let next = min(range.upperBound, max(range.lowerBound, ((value + step) / abs(step)).rounded() * abs(step)))
        recipe[field] = String(next)
    }

    private func choices(_ field: RecipeField, values: [String]) -> some View {
        let current = recipe[field]
        let options = values.contains(current) ? values : [current] + values
        return Menu {
            ForEach(options, id: \.self) { value in
                Button(value.isEmpty ? "Unspecified" : value) { recipe[field] = value }
            }
        } label: {
            Text(current.isEmpty ? "Unspecified" : current)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).studioSurface(fill: Studio.elevated)
        }.menuStyle(.borderlessButton)
    }
}
