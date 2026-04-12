package com.arolang.aro.run;

import com.intellij.execution.configurations.RunConfigurationOptions;
import com.intellij.openapi.components.StoredProperty;

public class ARORunConfigurationOptions extends RunConfigurationOptions {

    private final StoredProperty<String> commandType =
        string("run").provideDelegate(this, "commandType");

    private final StoredProperty<String> applicationDirectory =
        string("").provideDelegate(this, "applicationDirectory");

    public String getCommandType() {
        return commandType.getValue(this);
    }

    public void setCommandType(String value) {
        commandType.setValue(this, value);
    }

    public String getApplicationDirectory() {
        return applicationDirectory.getValue(this);
    }

    public void setApplicationDirectory(String value) {
        applicationDirectory.setValue(this, value);
    }
}
