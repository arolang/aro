package com.arolang.aro;

import com.intellij.openapi.application.PathManager;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.plugins.textmate.api.TextMateBundleProvider;

import java.io.IOException;
import java.io.InputStream;
import java.net.URL;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Objects;

/**
 * Provides the TextMate grammar bundle for ARO syntax highlighting.
 */
public class AROTextMateBundleProvider implements TextMateBundleProvider {

    private static final String[] BUNDLE_FILES = {
            "package.json",
            "language-configuration.json",
            "syntaxes/aro.tmLanguage.json"
    };

    @NotNull
    @Override
    public List<PluginBundle> getBundles() {
        try {
            Path aroBundleTmpDir = Files.createTempDirectory(
                    Path.of(PathManager.getTempPath()),
                    "textmate-aro"
            );

            for (String fileToCopy : BUNDLE_FILES) {
                URL resource = AROTextMateBundleProvider.class
                        .getClassLoader()
                        .getResource("textmate/aro-bundle/" + fileToCopy);

                try (InputStream resourceStream = Objects.requireNonNull(resource).openStream()) {
                    Path target = aroBundleTmpDir.resolve(fileToCopy);
                    Files.createDirectories(target.getParent());
                    Files.copy(resourceStream, target);
                }
            }

            PluginBundle aroBundle = new PluginBundle(
                    "ARO",
                    Objects.requireNonNull(aroBundleTmpDir)
            );
            return List.of(aroBundle);
        } catch (IOException e) {
            throw new RuntimeException("Failed to initialize ARO TextMate bundle", e);
        }
    }
}
