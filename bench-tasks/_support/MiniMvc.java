package bench;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.lang.annotation.Annotation;
import java.lang.reflect.*;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * A minimal in-process stand-in for Spring MVC, so generated controllers and
 * exception handlers can be exercised over "HTTP" without a server: it reads the
 * real mapping annotations, binds @PathVariable / @RequestParam / @RequestBody,
 * invokes the real controller method, serialises with Jackson, and routes
 * exceptions through the real @RestControllerAdvice / @ExceptionHandler methods.
 * Wrong paths, methods, annotations or status codes therefore fail the test.
 */
public final class MiniMvc {
    public record Response(int status, String body) {
        public String toString() { return status + " " + body; }
    }

    private static final class BindFailure extends RuntimeException { BindFailure(String m) { super(m); } }
    private static final String NONE = "\n\t\t\n\t\t\n\n\t\t\t\t\n";
    private final List<Object> controllers = new ArrayList<>();
    private final List<Object> advices = new ArrayList<>();
    private final ObjectMapper mapper = new ObjectMapper();

    public MiniMvc(Object... components) {
        for (Object c : components) {
            Class<?> k = c.getClass();
            if (k.isAnnotationPresent(RestControllerAdvice.class) || k.isAnnotationPresent(org.springframework.web.bind.annotation.ControllerAdvice.class)) advices.add(c);
            else controllers.add(c);
        }
    }

    public ObjectMapper json() { return mapper; }

    public Response get(String url) { return request("GET", url, null); }
    public Response post(String url, String body) { return request("POST", url, body); }

    public Response request(String httpMethod, String url, String body) {
        String path = url, query = "";
        int q = url.indexOf('?');
        if (q >= 0) { path = url.substring(0, q); query = url.substring(q + 1); }
        Map<String, String> params = new LinkedHashMap<>();
        for (String kv : query.split("&")) {
            if (kv.isEmpty()) continue;
            int e = kv.indexOf('=');
            String k = e < 0 ? kv : kv.substring(0, e), v = e < 0 ? "" : kv.substring(e + 1);
            params.put(URLDecoder.decode(k, StandardCharsets.UTF_8), URLDecoder.decode(v, StandardCharsets.UTF_8));
        }
        boolean pathMatched = false;
        for (Object ctl : controllers) {
            for (Method m : ctl.getClass().getMethods()) {
                for (Route r : routes(ctl.getClass(), m)) {
                    Map<String, String> vars = match(r.pattern, path);
                    if (vars == null) continue;
                    pathMatched = true;
                    if (!r.methods.contains(httpMethod)) continue;
                    return invoke(ctl, m, vars, params, body);
                }
            }
        }
        return new Response(pathMatched ? 405 : 404, "");
    }

    // ---- routing ----
    private record Route(String pattern, Set<String> methods) {}

    private List<Route> routes(Class<?> cls, Method m) {
        List<String> bases = new ArrayList<>(List.of(""));
        RequestMapping cm = cls.getAnnotation(RequestMapping.class);
        if (cm != null) { List<String> p = paths(cm.value(), cm.path()); if (!p.isEmpty()) bases = p; }
        List<String> subs; Set<String> methods = new HashSet<>();
        if (m.isAnnotationPresent(GetMapping.class)) { GetMapping a = m.getAnnotation(GetMapping.class); subs = paths(a.value(), a.path()); methods.add("GET"); }
        else if (m.isAnnotationPresent(PostMapping.class)) { PostMapping a = m.getAnnotation(PostMapping.class); subs = paths(a.value(), a.path()); methods.add("POST"); }
        else if (m.isAnnotationPresent(PutMapping.class)) { PutMapping a = m.getAnnotation(PutMapping.class); subs = paths(a.value(), a.path()); methods.add("PUT"); }
        else if (m.isAnnotationPresent(DeleteMapping.class)) { DeleteMapping a = m.getAnnotation(DeleteMapping.class); subs = paths(a.value(), a.path()); methods.add("DELETE"); }
        else if (m.isAnnotationPresent(RequestMapping.class)) {
            RequestMapping a = m.getAnnotation(RequestMapping.class); subs = paths(a.value(), a.path());
            if (a.method().length == 0) methods.addAll(List.of("GET", "POST", "PUT", "DELETE"));
            for (RequestMethod rm : a.method()) methods.add(rm.name());
        } else return List.of();
        if (subs.isEmpty()) subs = List.of("");
        List<Route> out = new ArrayList<>();
        for (String b : bases) for (String s : subs) out.add(new Route(norm(b + "/" + s), methods));
        return out;
    }
    private static List<String> paths(String[] a, String[] b) {
        List<String> l = new ArrayList<>(Arrays.asList(a)); l.addAll(Arrays.asList(b)); return l;
    }
    private static String norm(String p) {
        String s = ("/" + p).replaceAll("/+", "/");
        return s.length() > 1 && s.endsWith("/") ? s.substring(0, s.length() - 1) : s;
    }
    private static Map<String, String> match(String pattern, String path) {
        String[] pp = norm(pattern).split("/"), xp = norm(path).split("/");
        if (pp.length != xp.length) return null;
        Map<String, String> vars = new HashMap<>();
        for (int i = 0; i < pp.length; i++) {
            if (pp[i].startsWith("{") && pp[i].endsWith("}")) vars.put(pp[i].substring(1, pp[i].length() - 1), xp[i]);
            else if (!pp[i].equals(xp[i])) return null;
        }
        return vars;
    }

    // ---- invocation ----
    private Response invoke(Object ctl, Method m, Map<String, String> vars, Map<String, String> params, String body) {
        try {
            Parameter[] ps = m.getParameters();
            Object[] args = new Object[ps.length];
            for (int i = 0; i < ps.length; i++) {
                Parameter p = ps[i];
                PathVariable pv = p.getAnnotation(PathVariable.class);
                RequestParam rp = p.getAnnotation(RequestParam.class);
                if (pv != null) {
                    String name = first(pv.value(), pv.name(), p.getName());
                    args[i] = convert(vars.get(name), p.getType());
                } else if (p.isAnnotationPresent(RequestBody.class)) {
                    if (body == null || body.isBlank()) return new Response(400, "");
                    args[i] = mapper.readValue(body, p.getType());
                } else if (rp != null) {
                    String name = first(rp.value(), rp.name(), p.getName());
                    String v = params.get(name);
                    if (v == null && !NONE.equals(rp.defaultValue())) v = rp.defaultValue();
                    if (v == null) {
                        if (rp.required() || p.getType().isPrimitive()) return new Response(400, "");
                        args[i] = null;
                    } else args[i] = convert(v, p.getType());
                } else {
                    // unannotated simple parameter: Spring treats it as an optional request parameter
                    String v = params.get(p.getName());
                    args[i] = v == null ? null : convert(v, p.getType());
                }
            }
            Object result;
            try { result = m.invoke(ctl, args); }
            catch (InvocationTargetException e) { throw e.getCause(); }
            return toResponse(result, m);
        } catch (com.fasterxml.jackson.core.JsonProcessingException | NumberFormatException | BindFailure bind) {
            return new Response(400, "");
        } catch (Throwable t) {
            return handle(t);
        }
    }
    private static String first(String a, String b, String dflt) {
        return !a.isEmpty() ? a : !b.isEmpty() ? b : dflt;
    }
    private static Object convert(String v, Class<?> t) {
        if (v == null) throw new BindFailure("missing value");
        if (t == String.class) return v;
        if (t == int.class || t == Integer.class) return Integer.valueOf(v);
        if (t == long.class || t == Long.class) return Long.valueOf(v);
        if (t == double.class || t == Double.class) return Double.valueOf(v);
        if (t == boolean.class || t == Boolean.class) {
            if (v.equalsIgnoreCase("true")) return true;
            if (v.equalsIgnoreCase("false")) return false;
            throw new NumberFormatException("bad boolean");
        }
        throw new BindFailure("unsupported parameter type " + t);
    }

    // ---- exception routing ----
    private Response handle(Throwable thrown) {
        Method best = null; Object owner = null; int bestDist = Integer.MAX_VALUE;
        for (Object adv : advices) {
            for (Method h : adv.getClass().getMethods()) {
                ExceptionHandler eh = h.getAnnotation(ExceptionHandler.class);
                if (eh == null) continue;
                List<Class<?>> types = new ArrayList<>(Arrays.asList(eh.value()));
                if (types.isEmpty()) for (Class<?> pt : h.getParameterTypes()) if (Throwable.class.isAssignableFrom(pt)) types.add(pt);
                for (Class<?> ty : types) {
                    if (!ty.isInstance(thrown)) continue;
                    int d = 0; for (Class<?> c = thrown.getClass(); c != null && c != ty; c = c.getSuperclass()) d++;
                    if (d < bestDist) { bestDist = d; best = h; owner = adv; }
                }
            }
        }
        if (best == null) return new Response(500, "UNHANDLED " + thrown.getClass().getSimpleName());
        try {
            Class<?>[] pts = best.getParameterTypes(); Object[] a = new Object[pts.length];
            for (int i = 0; i < pts.length; i++) a[i] = pts[i].isInstance(thrown) ? thrown : null;
            return toResponse(best.invoke(owner, a), best);
        } catch (InvocationTargetException e) { return new Response(500, "HANDLER FAILED " + e.getCause()); }
        catch (Exception e) { return new Response(500, "HANDLER FAILED " + e); }
    }

    private Response toResponse(Object result, Method m) throws Exception {
        int status = 200;
        ResponseStatus rs = m.getAnnotation(ResponseStatus.class);
        if (rs != null) status = (rs.code() != HttpStatus.INTERNAL_SERVER_ERROR ? rs.code() : rs.value()).value();
        Object payload = result;
        if (result instanceof ResponseEntity<?> re) { status = re.getStatusCode().value(); payload = re.getBody(); }
        String json = payload == null ? "" : (payload instanceof String s ? s : mapper.writeValueAsString(payload));
        return new Response(status, json);
    }
}
