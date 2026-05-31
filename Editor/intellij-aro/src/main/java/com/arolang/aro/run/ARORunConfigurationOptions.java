package com.arolang.aro.run;

import com.intellij.execution.configurations.RunConfigurationOptions;
import com.intellij.openapi.components.StoredProperty;

public class ARORunConfigurationOptions extends RunConfigurationOptions {

    private final StoredProperty<String> commandType =
        string("run").provideDelegate(this, "commandType");

    private final StoredProperty<String> applicationDirectory =
        string("").provideDelegate(this, "applicationDirectory");

    /**
     * Issue #229 Phase 2 — when commandType is "debug", speak the Debug
     * Adapter Protocol over stdio so a DAP client (LSP4IJ / Cody /
     * external) can attach. Default: false (TUI mode in the console).
     */
    private final StoredProperty<Boolean> dapMode =
        property(false).provideDelegate(this, "dapMode");

    /**
     * Issue #229 Phase 2 — comma-separated initial breakpoints (line
     * numbers or verb names) passed via --breakpoint to `aro debug`.
     */
    private final StoredProperty<String> initialBreakpoints =
        string("").provideDelegate(this, "initialBreakpoints");

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

    public boolean getDapMode() {
        return dapMode.getValue(this);
    }

    public void setDapMode(boolean value) {
        dapMode.setValue(this, value);
    }

    public String getInitialBreakpoints() {
        return initialBreakpoints.getValue(this);
    }

    public void setInitialBreakpoints(String value) {
        initialBreakpoints.setValue(this, value);
    }
}
