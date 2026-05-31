package com.arolang.aro.run;

public enum AROCommandType {
    RUN("run", "Run"),
    DEBUG("debug", "Debug (step debugger — Issue #229)"),
    BUILD("build", "Build"),
    CHECK("check", "Check"),
    TEST("test", "Test"),
    REPL("repl", "REPL"),
    ASK("ask", "Ask (AI assistant)");

    private final String command;
    private final String displayName;

    AROCommandType(String command, String displayName) {
        this.command = command;
        this.displayName = displayName;
    }

    public String getCommand() {
        return command;
    }

    public String getDisplayName() {
        return displayName;
    }

    public static AROCommandType fromCommand(String command) {
        for (AROCommandType type : values()) {
            if (type.command.equals(command)) {
                return type;
            }
        }
        return RUN;
    }
}
