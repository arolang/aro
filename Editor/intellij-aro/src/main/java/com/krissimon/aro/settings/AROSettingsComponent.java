package com.krissimon.aro.settings;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.fileChooser.FileChooserDescriptorFactory;
import com.intellij.openapi.progress.ProgressIndicator;
import com.intellij.openapi.progress.ProgressManager;
import com.intellij.openapi.progress.Task;
import com.intellij.openapi.ui.TextBrowseFolderListener;
import com.intellij.openapi.ui.TextFieldWithBrowseButton;
import com.intellij.ui.components.JBCheckBox;
import com.intellij.ui.components.JBLabel;
import com.intellij.util.ui.FormBuilder;
import org.jetbrains.annotations.NotNull;

import javax.swing.*;
import java.awt.*;

public class AROSettingsComponent {
    private final JPanel panel;
    private final TextFieldWithBrowseButton aroPathField = new TextFieldWithBrowseButton();
    private final JBCheckBox debugLoggingCheckbox = new JBCheckBox("Enable debug logging");
    private final JButton validateButton = new JButton("Validate Path");
    private final JBLabel statusLabel = new JBLabel("");

    // Cache for validation results
    private String lastValidatedPath = "";
    private AROPathValidator.ValidationResult cachedResult = null;

    public AROSettingsComponent() {
        // Configure file chooser for ARO binary
        aroPathField.addBrowseFolderListener(
            new TextBrowseFolderListener(
                FileChooserDescriptorFactory.createSingleFileDescriptor()
                    .withTitle("Select ARO Binary")
            )
        );

        // Add validation button action
        validateButton.addActionListener(e -> validatePathAsync());

        // Create panel with validation status
        JPanel pathPanel = new JPanel(new BorderLayout());
        pathPanel.add(aroPathField, BorderLayout.CENTER);
        pathPanel.add(validateButton, BorderLayout.EAST);

        // Build form
        panel = FormBuilder.createFormBuilder()
            .addLabeledComponent(new JBLabel("ARO Binary Path:"), pathPanel, 1, false)
            .addComponent(statusLabel)
            .addComponent(debugLoggingCheckbox)
            .addComponentFillVertically(new JPanel(), 0)
            .getPanel();
    }

    private void validatePathAsync() {
        String path = aroPathField.getText().trim();
        if (path.isEmpty()) {
            statusLabel.setText("Please enter a path");
            statusLabel.setForeground(Color.RED);
            return;
        }

        // Check cache
        if (path.equals(lastValidatedPath) && cachedResult != null) {
            updateStatusLabel(cachedResult);
            return;
        }

        // Run validation asynchronously to avoid blocking the UI thread
        ProgressManager.getInstance().run(new Task.Backgroundable(null, "Validating ARO Binary", false) {
            private AROPathValidator.ValidationResult result;

            @Override
            public void run(@NotNull ProgressIndicator indicator) {
                indicator.setText("Validating ARO binary at: " + path);
                result = AROPathValidator.validate(path);
            }

            @Override
            public void onSuccess() {
                // Cache the result
                lastValidatedPath = path;
                cachedResult = result;

                // Update UI on EDT
                ApplicationManager.getApplication().invokeLater(() -> updateStatusLabel(result));
            }

            @Override
            public void onThrowable(@NotNull Throwable error) {
                ApplicationManager.getApplication().invokeLater(() -> {
                    statusLabel.setText("Validation error: " + error.getMessage());
                    statusLabel.setForeground(Color.RED);
                });
            }
        });
    }

    private void updateStatusLabel(AROPathValidator.ValidationResult result) {
        if (result.valid) {
            statusLabel.setText("✓ Valid ARO binary: " + result.message);
            statusLabel.setForeground(new Color(0, 128, 0));
        } else {
            statusLabel.setText("✗ " + result.message);
            statusLabel.setForeground(Color.RED);
        }
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
