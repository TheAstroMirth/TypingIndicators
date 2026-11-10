import { disableStyle, enableStyle } from "@api/Styles";
import { definePluginSettings } from "@api/Settings";
import ErrorBoundary from "@components/ErrorBoundary";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { filters, findAll, findByProps, findStoreLazy } from "@webpack";
import { FluxDispatcher, React, SelectedChannelStore, UserStore } from "@webpack/common";

import style from "./style.css?managed";

const TypingStore = findStoreLazy("TypingStore");
const logger = new Logger("TypingIndicators");

const WORDS: Record<number, string> = { 0: "typing", 1: "yapping", 2: "venting", 3: "oversharing", 4: "barking", 5: "babbling", 6: "daydreaming", 7: "meowing" };
const ANIMS: Record<number, string> = { 0: "none", 1: "pulse", 2: "ring", 3: "wave" };
const STAGGER: Record<string, number> = { pulse: 0.32, wave: 0.32, ring: 0.3 };

const applyVars = () => {
    const root = document.documentElement.style;
    root.setProperty("--cti-shift", String(settings.store.shift));
    root.setProperty("--cti-max-width", settings.store.maxWidth + "px");
};

const settings = definePluginSettings({
    shift: {
        type: OptionType.NUMBER,
        description: "Left shift of the typing bar in px",
        default: 26,
        onChange: applyVars
    },
    maxUsers: {
        type: OptionType.SLIDER,
        description: "Show indicators when up to this many people are typing",
        markers: [1, 2, 3],
        default: 1,
        stickToMarkers: true
    },
    maxWidth: {
        type: OptionType.NUMBER,
        description: "Max width of the typing text in px, longer text ends in ...",
        default: 400,
        onChange: applyVars
    }
});

const cache = new Map<string, any>();
const warned = new Set<string>();
const hooks: (() => void)[] = [];

const lookup = (table: Record<number, string>, kind: string, n: number, fallback: string) => {
    if (n in table) return table[n];
    if (!warned.has(kind + n)) {
        warned.add(kind + n);
        logger.warn(`unknown ${kind} value ${n}, falling back`);
    }
    return fallback;
};

const typers = () => {
    const me = UserStore.getCurrentUser().id;
    const ids = Object.keys(TypingStore.getTypingUsers(SelectedChannelStore.getChannelId()) ?? {}).filter(id => id !== me);
    return ids.length && ids.length <= settings.store.maxUsers ? ids : [];
};

const cfgOf = (id: string) => (UserStore.getUser(id) as any)?.typingIndicatorStyle ?? cache.get(id);

const Row = ErrorBoundary.wrap(({ cfg }: { cfg: any; }) => {
    const anim = lookup(ANIMS, "animation", cfg.animation ?? 0, "none");
    const emojis: any[] = Array.isArray(cfg.emojis) ? cfg.emojis : [];
    return (
        <span className={"cti-emojis cti-" + anim}>
            {emojis.map((e, i) => {
                const st = { animationDelay: i * (STAGGER[anim] ?? 0) + "s" };
                return e.id
                    ? <img key={i} style={st} src={`https://cdn.discordapp.com/emojis/${e.id}.${e.animated ? "gif" : "webp"}?size=44&quality=lossless`} />
                    : <span key={i} style={st}>{e.name ?? ""}</span>;
            })}
        </span>
    );
}, { noop: true });

const flat = (c: any): any[] => Array.isArray(c) ? c.flatMap(flat) : [c];
const swapWord = (c: any, word: string): any => Array.isArray(c) ? c.map(x => swapWord(x, word)) :
    typeof c === "string" ? c.replace(/\btyping\b/, word) : c;

const rowFor = (id: string) => {
    const cfg = cfgOf(id);
    if (!cfg?.emojis?.length) return null;
    const key = "cti|" + id + "|" + (cfg.animation ?? 0) + "|" + cfg.emojis.map((e: any) => e.id ?? e.name).join(",");
    return <Row key={key} cfg={cfg} />;
};

const mutate = (props: any) => {
    const ids = typers();
    if (!ids.length) return props;

    let n = 0;
    const withRows = (c: any): any => {
        if (Array.isArray(c)) return c.map(withRows);
        if (c?.type !== "strong" || n >= ids.length) return c;
        const row = rowFor(ids[n++]);
        return row ? <React.Fragment key={"cti-f" + n}>{row}{c}</React.Fragment> : c;
    };
    let children = withRows(props.children);

    if (n === 0) children = [ids.map(rowFor), children];
    if (ids.length === 1) {
        const cfg = cfgOf(ids[0]);
        if (cfg) children = swapWord(children, lookup(WORDS, "typingSuggestion", cfg.typingSuggestion ?? 0, "typing"));
    }

    return { ...props, className: (props.className ?? "") + " cti-text", children };
};

const isTypingText = (type: any, props: any) => {
    if (type !== "span" || !props || props.children == null) return false;
    const cls = typeof props.className === "string" ? props.className : "";
    if (props["aria-atomic"] === undefined && !/(^|\s)text_/.test(cls)) return false;
    return flat(props.children).some(c => c?.type === "strong" || (typeof c === "string" && /typing/.test(c)));
};

const isTweaksProps = (type: any, props: any) =>
    typeof type !== "string" &&
    props != null &&
    Array.isArray(props.users) &&
    Array.isArray(props.children) &&
    "guildId" in props &&
    props.users.every((u: any) => typeof u?.id === "string");

const isNameSlot = (c: any) =>
    c != null && (c.type === "strong" || (typeof c !== "string" && !React.isValidElement(c)));

const mutateTweaks = (props: any) => {
    const users: any[] = props.users;
    const me = UserStore.getCurrentUser().id;
    if (!users.length || users.length > settings.store.maxUsers || users.some(u => u.id === me)) return props;

    let n = 0;
    let rowsAdded = 0;
    const out: any[] = [];
    for (const c of props.children) {
        if (isNameSlot(c) && n < users.length) {
            const row = rowFor(users[n++].id);
            if (row) { out.push(row); rowsAdded++; }
        }
        out.push(c);
    }

    let children: any = out;
    if (users.length === 1) {
        const cfg = cfgOf(users[0].id);
        if (cfg) children = swapWord(children, lookup(WORDS, "typingSuggestion", cfg.typingSuggestion ?? 0, "typing"));
    }

    if (!rowsAdded && children === out) return props;
    return { ...props, children };
};

const hook = (obj: any, name: string) => {
    const orig = obj?.[name];
    if (typeof orig !== "function" || orig.__cti) return;
    const wrapped = function (this: any, type: any, props: any, ...rest: any[]) {
        try {
            if (isTypingText(type, props)) props = mutate(props);
            else if (isTweaksProps(type, props)) props = mutateTweaks(props);
        } catch (e) { logger.warn("hook failed", e); }
        return orig.call(this, type, props, ...rest);
    };
    (wrapped as any).__cti = true;
    try { obj[name] = wrapped; } catch { return; }
    if (obj[name] === wrapped) hooks.push(() => { obj[name] = orig; });
};

export default definePlugin({
    name: "TypingIndicators",
    description: "Shows other users' custom typing indicators (emojis, status word, animation) in the native typing bar",
    authors: [{ name: "AstroMirth", id: 1456018726074847285n }],
    settings,

    flux: {
        TYPING_START({ userId, customTypingIndicatorConfig }: any) {
            if (customTypingIndicatorConfig !== undefined) cache.set(userId, customTypingIndicatorConfig);
        }
    },

    start() {
        applyVars();
        enableStyle(style);

        let rts: any[] = [];
        try { rts = findAll(filters.byProps("jsx", "jsxs")); } catch { }
        if (!rts.length) { try { rts = [findByProps("jsx", "jsxs")]; } catch { } }
        for (const rt of rts) { hook(rt, "jsx"); hook(rt, "jsxs"); hook(rt, "jsxDEV"); }
        let rc: any[] = [];
        try { rc = findAll(filters.byProps("createElement", "useState")); } catch { }
        for (const r of rc) hook(r, "createElement");
        hook(React, "createElement");
        if (!hooks.length) logger.warn("could not hook React jsx/createElement");
    },

    stop() {
        hooks.splice(0).forEach(f => f());
        disableStyle(style);
        document.documentElement.style.removeProperty("--cti-shift");
        document.documentElement.style.removeProperty("--cti-max-width");
        cache.clear();
    }
});
