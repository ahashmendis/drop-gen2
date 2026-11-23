package bench;

import java.util.function.Supplier;

/**
 * Tiny dependency-free test runner shared by every benchmark task.
 * Output contract (parsed by Drop's benchmark engine), one line per test:
 *   TEST<TAB>id<TAB>PASS
 *   TEST<TAB>id<TAB>FAIL<TAB>one-line reason
 * Each test is isolated: an exception or failed assertion fails that test only.
 */
public final class Check {
    public interface Body { void run() throws Exception; }
    private Check() {}

    public static void test(String id, Body body) {
        try {
            body.run();
            System.out.println("TEST\t" + id + "\tPASS");
        } catch (Throwable t) {
            Throwable r = t;
            if (r instanceof java.lang.reflect.InvocationTargetException && r.getCause() != null) r = r.getCause();
            String msg = String.valueOf(r.getMessage()).replaceAll("[\\r\\n\\t]+", " ");
            if (msg.length() > 300) msg = msg.substring(0, 300) + "...";
            System.out.println("TEST\t" + id + "\tFAIL\t" + r.getClass().getSimpleName() + ": " + msg);
        }
    }

    public static void eq(Object expected, Object actual, String what) {
        if (!java.util.Objects.equals(expected, actual))
            throw new AssertionError(what + ": expected <" + expected + "> but was <" + actual + ">");
    }
    public static void isTrue(boolean cond, String what) {
        if (!cond) throw new AssertionError(what);
    }
    /** The call must throw exactly the given exception type (or a subclass). */
    public static void throwsA(Class<? extends Throwable> type, String what, Body body) {
        try { body.run(); }
        catch (Throwable t) {
            Throwable r = t;
            if (r instanceof java.lang.reflect.InvocationTargetException && r.getCause() != null) r = r.getCause();
            if (type.isInstance(r)) return;
            throw new AssertionError(what + ": expected " + type.getSimpleName() + " but got " + r.getClass().getSimpleName() + ": " + r.getMessage());
        }
        throw new AssertionError(what + ": expected " + type.getSimpleName() + " but nothing was thrown");
    }
    public static <T> T get(Supplier<T> s) { return s.get(); }

    /** Instantiate a class the SOLUTION must create (looked up by name, matched by argument types). */
    public static Object make(String className, Object... args) throws Exception {
        Class<?> c = Class.forName(className);
        for (java.lang.reflect.Constructor<?> k : c.getConstructors()) {
            Class<?>[] pt = k.getParameterTypes();
            if (pt.length != args.length) continue;
            boolean ok = true;
            for (int i = 0; i < pt.length; i++) ok &= wrap(pt[i]).isInstance(args[i]);
            if (ok) return k.newInstance(args);
        }
        throw new NoSuchMethodException(className + " has no public constructor for " + java.util.Arrays.toString(args));
    }
    private static Class<?> wrap(Class<?> t) {
        if (!t.isPrimitive()) return t;
        if (t == int.class) return Integer.class; if (t == long.class) return Long.class;
        if (t == boolean.class) return Boolean.class; if (t == double.class) return Double.class;
        return t;
    }
    /** Source text of a solution file (for the few static checks), "" when unreadable. */
    public static String source(String relPathUnderSrcMainJava) {
        try { return java.nio.file.Files.readString(java.nio.file.Path.of(System.getProperty("bench.src", "."), relPathUnderSrcMainJava)); }
        catch (Exception e) { return ""; }
    }
}
