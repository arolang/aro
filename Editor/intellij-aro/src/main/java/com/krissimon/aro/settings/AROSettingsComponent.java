package com.krissimon.aro.settings;

import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory;
import com.intellij.openapi.ui.TextBrowseFolderListener;
import com.intellij.openapi.ui.TextFieldWithBrowseButton;
import com.intellij.ui.components.JBCheckBox;
import com.intellij.ui.components.JBLabel;
import com.intellij.util.ui.FormBuilder;
import org.jetbrains.annotations.NotNull;

import javax.swing.*;

public class AROSettingsComponent {
    private final JPanel panel;
    private final TextFieldWithBrowseButton aroPathField = new TextFieldWithBrowseButton();
    private final JBCheckBox debugLoggingCheckbox = new JBCheckBox("Enable debug logging");
    private final JBLabel statusLabel = new JBLabel("");

    public AROSettingsComponent() {
        // Configure file chooser for ARO binary
        aroPathField.addBrowseFolderListener(
            new TextBrowseFolderListener(
                FileChooserDescriptorFactory.createSingleFileDescriptor()
                    .withTitle("Select ARO Binary")
            )
        );

        // Build form
        panel = FormBuilder.createFormBuilder()
            .addLabeledComponent(new JBLabel("ARO Binary Path:"), aroPathField, 1, false)
            .addComponent(debugLoggingCheckbox)
            .addComponentFillVertically(new JPanel(), 0)
            .getPanel();
    }

    public JPanel getPanel() {
        return panel;
    }

    @NotNull
    public String getAroPath() {
        return aroPathField.getText();
    }

    public void setAroPath(@NotNull String path) {
        aroPathField.setText(path);
    }

    public boolean getEnableDebugLogging() {
        return debugLoggingCheckbox.isSelected();
    }

    public void setEnableDebugLogging(boolean enabled) {
        debugLoggingCheckbox.setSelected(enabled);
    }
}
