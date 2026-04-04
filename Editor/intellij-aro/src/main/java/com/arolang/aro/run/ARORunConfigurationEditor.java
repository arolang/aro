package com.arolang.aro.run;

import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory;
import com.intellij.openapi.options.SettingsEditor;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.ui.ComboBox;
import com.intellij.openapi.ui.TextBrowseFolderListener;
import com.intellij.openapi.ui.TextFieldWithBrowseButton;
import com.intellij.ui.components.JBLabel;
import com.intellij.util.ui.FormBuilder;
import org.jetbrains.annotations.NotNull;

import javax.swing.*;
import java.awt.*;

public class ARORunConfigurationEditor extends SettingsEditor<ARORunConfiguration> {

    private final ComboBox<AROCommandType> commandTypeCombo;
    private final TextFieldWithBrowseButton directoryField;

    public ARORunConfigurationEditor(Project project) {
        commandTypeCombo = new ComboBox<>(AROCommandType.values());
        commandTypeCombo.setRenderer(new DefaultListCellRenderer() {
            @Override
            public Component getListCellRendererComponent(JList<?> list, Object value, int index, boolean isSelected, boolean cellHasFocus) {
                super.getListCellRendererComponent(list, value, index, isSelected, cellHasFocus);
                if (value instanceof AROCommandType type) {
                    setText(type.getDisplayName());
                }
                return this;
            }
        });

        directoryField = new TextFieldWithBrowseButton();
        directoryField.addBrowseFolderListener(
            new TextBrowseFolderListener(
                FileChooserDescriptorFactory.createSingleFolderDescriptor()
                    .withTitle("Select ARO Application Directory")
            )
        );
    }

    @Override
    protected void resetEditorFrom(@NotNull ARORunConfiguration config) {
        commandTypeCombo.setSelectedItem(config.getCommandType());
        directoryField.setText(config.getApplicationDirectory());
    }

    @Override
    protected void applyEditorTo(@NotNull ARORunConfiguration config) {
        config.setCommandType((AROCommandType) commandTypeCombo.getSelectedItem());
        config.setApplicationDirectory(directoryField.getText().trim());
    }

    @Override
    protected @NotNull JComponent createEditor() {
        return FormBuilder.createFormBuilder()
            .addLabeledComponent(new JBLabel("Command:"), commandTypeCombo, 1, false)
            .addLabeledComponent(new JBLabel("Application directory:"), directoryField, 1, false)
            .addComponentFillVertically(new JPanel(), 0)
            .getPanel();
    }
}
