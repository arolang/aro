package com.krissimon.aro.settings;

import com.intellij.openapi.application.ApplicationManager;
import com.intellij.openapi.components.PersistentStateComponent;
import com.intellij.openapi.components.Service;
import com.intellij.openapi.components.State;
import com.intellij.openapi.components.Storage;
import com.intellij.util.xmlb.XmlSerializerUtil;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

@Service
@State(
    name = "com.krissimon.aro.settings.AROSettingsState",
    storages = @Storage("AROSettings.xml")
)
public final class AROSettingsState implements PersistentStateComponent<AROSettingsState> {
    public String aroPath = "aro";
    public boolean enableDebugLogging = false;

    public static AROSettingsState getInstance() {
        return ApplicationManager.getApplication().getService(AROSettingsState.class);
    }

    @Nullable
    @Override
    public AROSettingsState getState() {
        return this;
    }

    @Override
    public void loadState(@NotNull AROSettingsState state) {
        XmlSerializerUtil.copyBean(state, this);
    }
}
