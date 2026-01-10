package com.arolang.aro.settings;

import com.intellij.openapi.options.Configurable;
import com.intellij.openapi.util.NlsContexts;
import org.jetbrains.annotations.Nullable;

import javax.swing.*;

public class AROSettingsConfigurable implements Configurable {
    private AROSettingsComponent component;

    @NlsContexts.ConfigurableName
    @Override
    public String getDisplayName() {
        return "ARO Language";
    }

    @Nullable
    @Override
    public JComponent createComponent() {
        component = new AROSettingsComponent();
        return component.getPanel();
    }

    @Override
    public boolean isModified() {
        AROSettingsState settings = AROSettingsState.getInstance();
        return !component.getAroPath().equals(settings.aroPath) ||
               component.getEnableDebugLogging() != settings.enableDebugLogging;
    }

    @Override
    public void apply() {
        AROSettingsState settings = AROSettingsState.getInstance();
        settings.aroPath = component.getAroPath();
        settings.enableDebugLogging = component.getEnableDebugLogging();
    }

    @Override
    public void reset() {
        AROSettingsState settings = AROSettingsState.getInstance();
        component.setAroPath(settings.aroPath);
        component.setEnableDebugLogging(settings.enableDebugLogging);
    }

    @Override
    public void disposeUIResources() {
        component = null;
    }
}
