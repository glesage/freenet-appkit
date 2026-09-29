# JNA looks up classes and fields by name, and the UniFFI bindings register
# callbacks through JNA structures.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.freenet.mobile.** { *; }
-dontwarn java.awt.**
