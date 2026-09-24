allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// file_picker 8.x is compiled against android-34, but a plugin it depends on
// (flutter_plugin_android_lifecycle) now demands compileSdk >= 36, so the
// release build fails its AAR metadata check.  Raise every Android subproject
// to 36 without touching the pinned plugin sources.
//
// This MUST be registered before the evaluationDependsOn(":app") block below:
// that block forces the subprojects to evaluate, and afterEvaluate() cannot be
// added to an already-evaluated project.
subprojects {
    afterEvaluate {
        val androidExtension =
            project.extensions.findByName("android") ?: return@afterEvaluate
        val setter = androidExtension.javaClass.methods.firstOrNull { method ->
            method.name == "compileSdkVersion" &&
                method.parameterTypes.size == 1 &&
                method.parameterTypes[0] == Integer.TYPE
        }
        setter?.invoke(androidExtension, 36)
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
