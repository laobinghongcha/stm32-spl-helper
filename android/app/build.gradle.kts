import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// 发布签名配置
//
// 密钥库与口令**不进版本库**（android/key.properties 已在 .gitignore 里）。
// 找不到配置时回退到 debug 签名，这样：
//   - 本机没配密钥也能照常 `flutter build apk --release` 验证功能
//   - CI / 别人的机器上不会因为缺文件而构建失败
// 代价是"回退构建"出来的 APK 不能用于正式分发，
// 所以下面用 println 明确打出来，避免误以为已经签好了。
// ---------------------------------------------------------------------------
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "io.github.laobinghongcha.stm32helper"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.laobinghongcha.stm32helper"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // storeFile 在 key.properties 里写的是相对 android/ 的文件名，
                // 而 file() 默认相对**当前模块**（android/app/）解析，
                // 直接用会找不到文件。所以显式相对 rootProject 解析。
                storeFile = rootProject.file(
                    keystoreProperties.getProperty("storeFile")
                )
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                println(
                    "[build] 未找到 android/key.properties，" +
                        "release 将使用 debug 签名（仅供本机验证，不可分发）。"
                )
                signingConfigs.getByName("debug")
            }
            // 正式包不做代码压缩混淆：本项目没有反射/序列化框架，
            // 混淆收益有限，而一旦出问题（比如 sqflite 的模型类被改名）
            // 排查成本很高。需要的话再单独开。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
