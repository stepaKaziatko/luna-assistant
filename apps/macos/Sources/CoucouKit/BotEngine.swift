import Foundation
import CoreGraphics
import QuartzCore
import SwiftUI

// MARK: - Easing functions (same as prototype: E.out, E.inOut, E.back, E.lin)

enum Ease {
    static func out(_ t: CGFloat) -> CGFloat   { 1 - pow(1 - t, 3) }
    static func inOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2, 3)/2 }
    static func back(_ t: CGFloat) -> CGFloat  { let c1: CGFloat = 1.7; let c3 = c1+1; return 1+c3*pow(t-1,3)+c1*pow(t-1,2) }
    static func lin(_ t: CGFloat) -> CGFloat   { t }
}

// MARK: - Tween key: [target, duration_ms, easing]

struct TweenKey {
    let target: CGFloat
    let duration: CGFloat    // milliseconds
    let ease: (CGFloat) -> CGFloat
}

struct Tween {
    let property: String
    var keys: [TweenKey]
    var keyIndex: Int = 0
    var from: CGFloat
    var startTime: Double    // CACurrentMediaTime() * 1000
    var onComplete: (() -> Void)? = nil
}

// MARK: - Particle

struct Particle {
    enum ParticleType { case heart, star, spark, sweat, z }
    var type: ParticleType
    var x, y, vx, vy: CGFloat
    var age: Double        // seconds
    var life: Double
    var rot: CGFloat
    var size: CGFloat
}

// MARK: - Bot state config (mirrors STATES in prototype)

struct BotStateCfg {
    let color: CGColor
    let tint: CGFloat
    let eye: EyeShape
    let badge: BadgeType?
    let badgeColor: CGColor
    let glow: CGColor
    let glowOpacity: CGFloat
    let bounces: Bool
    let scans: Bool
    let breathes: Bool
    let zz: Bool
    let sweat: Bool
    let look: CGPoint?     // fixed look direction
    let tilt: CGFloat
    let sound: String?
}

enum EyeShape: String {
    case pill, wide, dot, line, flat, happy, closed, spiral, heart, star, tired, wink, cup
}

enum BadgeType {
    case dots(CGColor)
    case bang(CGColor)
    case question(CGColor)
    case dot(CGColor)
}

// MARK: - Luna track constants (from PISTES.mochi)

enum MochiConst {
    // Глаза малыша: крупнее, шире расставлены и сидят ниже середины тела.
    static let eyeW: CGFloat  = 0.28
    static let eyeH: CGFloat  = 0.34
    static let eyeSp: CGFloat = 0.42
    static let eyeP: CGFloat  = -0.20
    // Цвета и форма живут в LunaLook; здесь только CGColor-обёртки для движка.
    static let baseTop    = CGColor(red: LunaLook.bodyTop.r, green: LunaLook.bodyTop.g,
                                    blue: LunaLook.bodyTop.b, alpha: 1)
    static let baseBottom = CGColor(red: LunaLook.bodyBottom.r, green: LunaLook.bodyBottom.g,
                                    blue: LunaLook.bodyBottom.b, alpha: 1)
    /// Глаза на светлом теле (цвет агента, тыква).
    static let ink        = CGColor(red: LunaLook.ink.r, green: LunaLook.ink.g, blue: LunaLook.ink.b, alpha: 1)
    static let miniInk    = CGColor(red: 0.063, green: 0.075, blue: 0.102, alpha: 1)  // #10131A
    /// Светящиеся глаза на тёмном теле.
    static let glow       = CGColor(red: LunaLook.glow.r, green: LunaLook.glow.g,
                                    blue: LunaLook.glow.b, alpha: 1)
}

extension Outfit {
    /// Закрывает ли наряд макушку: тогда полумесяц и звёздочка над головой не рисуются.
    var coversHead: Bool {
        switch self {
        case .beanie, .santaHat, .partyHat, .crown, .witchHat, .bunnyEars, .pumpkin, .bow: return true
        default: return false
        }
    }
}

// MARK: - Bot state configs

let BotStates: [BotState: BotStateCfg] = [
    .idle: BotStateCfg(
        color: CGColor(red:0.902,green:0.914,blue:0.933,alpha:1), tint:0,
        eye:.pill, badge:nil,
        badgeColor: .white, glow: CGColor(red:1,green:1,blue:1,alpha:0.35), glowOpacity:0.25,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:nil),
    .working: BotStateCfg(
        color: CGColor(red:0.231,green:0.620,blue:1,alpha:1), tint:0.72,
        eye:.pill, badge:.dots(CGColor(red:0.231,green:0.620,blue:1,alpha:1)),
        badgeColor: CGColor(red:0.231,green:0.620,blue:1,alpha:1),
        glow: CGColor(red:0.231,green:0.620,blue:1,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"work"),
    .thinking: BotStateCfg(
        color: CGColor(red:0.545,green:0.361,blue:0.965,alpha:1), tint:0.72,
        eye:.pill, badge:.dots(CGColor(red:0.545,green:0.361,blue:0.965,alpha:1)),
        badgeColor: CGColor(red:0.545,green:0.361,blue:0.965,alpha:1),
        glow: CGColor(red:0.545,green:0.361,blue:0.965,alpha:1), glowOpacity:0.5,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look: CGPoint(x:0.55, y:0.55), tilt:0, sound:"think"),
    .searching: BotStateCfg(
        color: CGColor(red:0.388,green:0.396,blue:0.949,alpha:1), tint:0.72,
        eye:.pill, badge:.dots(CGColor(red:0.388,green:0.396,blue:0.949,alpha:1)),
        badgeColor: CGColor(red:0.388,green:0.396,blue:0.949,alpha:1),
        glow: CGColor(red:0.388,green:0.396,blue:0.949,alpha:1), glowOpacity:0.55,
        bounces:false, scans:true, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"search"),
    .approval: BotStateCfg(
        color: CGColor(red:0.961,green:0.647,blue:0.141,alpha:1), tint:0.78,
        eye:.wide, badge:.bang(CGColor(red:0.961,green:0.647,blue:0.141,alpha:1)),
        badgeColor: CGColor(red:0.961,green:0.647,blue:0.141,alpha:1),
        glow: CGColor(red:0.961,green:0.647,blue:0.141,alpha:1), glowOpacity:0.6,
        bounces:true, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"approval"),
    .question: BotStateCfg(
        color: CGColor(red:0.133,green:0.827,blue:0.933,alpha:1), tint:0.75,
        eye:.pill, badge:.question(CGColor(red:0.133,green:0.827,blue:0.933,alpha:1)),
        badgeColor: CGColor(red:0.133,green:0.827,blue:0.933,alpha:1),
        glow: CGColor(red:0.133,green:0.827,blue:0.933,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0.17, sound:"question"),
    .error: BotStateCfg(
        color: CGColor(red:0.957,green:0.314,blue:0.369,alpha:1), tint:0.78,
        eye:.flat, badge:.dot(CGColor(red:0.957,green:0.314,blue:0.369,alpha:1)),
        badgeColor: CGColor(red:0.957,green:0.314,blue:0.369,alpha:1),
        glow: CGColor(red:0.957,green:0.314,blue:0.369,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"error"),
    .finished: BotStateCfg(
        color: CGColor(red:0.204,green:0.831,blue:0.600,alpha:1), tint:0.35,
        eye:.happy, badge:.dot(CGColor(red:0.204,green:0.831,blue:0.600,alpha:1)),
        badgeColor: CGColor(red:0.204,green:0.831,blue:0.600,alpha:1),
        glow: CGColor(red:0.204,green:0.831,blue:0.600,alpha:1), glowOpacity:0.5,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"finish"),
    .ratelimit: BotStateCfg(
        color: CGColor(red:0.984,green:0.573,blue:0.235,alpha:1), tint:0.72,
        eye:.tired, badge:.dot(CGColor(red:0.984,green:0.573,blue:0.235,alpha:1)),
        badgeColor: CGColor(red:0.984,green:0.573,blue:0.235,alpha:1),
        glow: CGColor(red:0.984,green:0.573,blue:0.235,alpha:1), glowOpacity:0.45,
        bounces:false, scans:false, breathes:false, zz:false, sweat:true,
        look:nil, tilt:0, sound:"rate"),
    .sleeping: BotStateCfg(
        color: CGColor(red:0.580,green:0.635,blue:0.722,alpha:1), tint:0.32,
        eye:.closed, badge:nil,
        badgeColor: .white,
        glow: CGColor(red:0.580,green:0.635,blue:0.722,alpha:1), glowOpacity:0.2,
        bounces:false, scans:false, breathes:true, zz:true, sweat:false,
        look:nil, tilt:0, sound:"sleep"),
    .dizzy: BotStateCfg(
        color: CGColor(red:0.957,green:0.447,blue:0.714,alpha:1), tint:0.7,
        eye:.spiral, badge:nil,
        badgeColor: .white,
        glow: CGColor(red:0.957,green:0.447,blue:0.714,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"dizzy"),
]

// MARK: - Bot engine

@MainActor
final class BotEngine: ObservableObject {
    var isMini: Bool = false
    var bodyColor: CGColor? = nil    // override for mini bots

    // Animation state (mirrors prototype 's' object)
    var yaw:    CGFloat = 0
    var pitch:  CGFloat = 0
    var roll:      CGFloat = 0
    var rollTurns: CGFloat = 1
    var tilt:   CGFloat = 0
    var open:   CGFloat = 1          // eye open amount
    var sx:     CGFloat = 1          // scale X
    var sy:     CGFloat = 1          // scale Y
    var oy:     CGFloat = 0          // offset Y (bounce)
    var ox:     CGFloat = 0          // offset X (shake)
    var tint:   CGFloat = 0
    var morph:  CGFloat = 0          // morph to rect (for upload bucket)
    var hands:  CGFloat = 0
    var blush:  CGFloat = 0
    var outfit: Outfit = .none
    var es:     CGFloat = 1          // eye scale
    var badgeS: CGFloat = 0          // badge scale
    var outfitPresence: CGFloat = 0  // 0=hidden, 1=fully visible (animated)
    private var outfitTarget: Outfit = .none

    // Physical spring (hat/pompom lag) — updated in update()
    var physDx: CGFloat = 0   // horizontal lag (-1..1)
    var physDy: CGFloat = 0   // vertical lag (-1..1)
    private var physVx: CGFloat = 0
    private var physVy: CGFloat = 0
    private var prevYaw: CGFloat = 0
    private var prevOy: CGFloat = 0
    private var prevRoll: CGFloat = 0

    // Targets
    var tgYaw:    CGFloat = 0
    var tgPitch:  CGFloat = 0
    var tgTilt:   CGFloat = 0
    var tgSy:     CGFloat = 1
    var tgSx:     CGFloat = 1
    var tgEs:     CGFloat = 1   // eye-scale target (hover love: 1.08, normal: 1)

    // Particle canvas overhang (extra canvas height at top for hearts to fly into)
    var particleOverhang: CGFloat = 0

    // Mouth spring (fraction of R: 0=closed, 0.20=hover, 0.42=open, 0.50=overopen)
    var slotH: CGFloat = 0           // current height (fraction of R)
    var slotHTarget: CGFloat = 0     // spring target
    var slotHVel: CGFloat = 0        // spring velocity (fraction of R / s)
    var isChewing: Bool = false       // true for ~800ms after gulp swallow

    // Color (animated)
    var col:  (CGFloat, CGFloat, CGFloat) = (0.902, 0.914, 0.933)  // idle
    var colT: (CGFloat, CGFloat, CGFloat) = (0.902, 0.914, 0.933)

    // State
    var state: BotState = .idle
    var cfg: BotStateCfg = BotStates[.idle]!

    // Eye override (emote)
    var eyeOverride: EyeShape? = nil
    var eyeOverrideUntil: Double = 0   // CACurrentMediaTime()
    var permanentEye: EyeShape? = nil   // restored after temporary emote/blink expires
    var permanentEmote: BotEmote? = nil // stored so doMiniBehaviorLoop can switch on it
    var miniNextBehavior: Double = 0    // CACurrentMediaTime() of next periodic mini action

    // Badge animation
    var badge: BadgeType? = nil
    var badgeKey: String = "none"
    var badgeToken: Int = 0

    // Tweens (keyed by property name)
    var tweens: [String: Tween] = [:]
    var locks:  Set<String> = []

    // Particles
    var particles: [Particle] = []

    // Look target
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0

    // Timing
    var lastTime: Double = CACurrentMediaTime()
    /// Fractional engine steps owed when drawing slower than the display (Mac mini Lunas).
    var stepDebt: Double = 0
    var t0: Double = CACurrentMediaTime() - Double.random(in: 0...5)
    var nextBlink: Double = CACurrentMediaTime() + 1.5 + Double.random(in: 0...2)
    var waveUntil: Double = 0
    var waveStart: Double = 0     // CACurrentMediaTime() when wave animation began
    var greetToken: Int = 0       // incremented to invalidate stale greet closures
    var lastAmbient: Double = 0

    // Slap tracking (for dizzy on 3 slaps)
    var slapTimes: [Double] = []

    // Listening mode
    var listenHandRaise: CGFloat = 0   // 0=rest, 1=raised to listening position (right hand)
    var listeningLevel:  CGFloat = 0   // smoothed mic level 0…1, set each frame by BotCanvasView
    var isInListeningMode  = false
    var listeningHasWords  = false
    private var listeningPrevPermanentEmote: BotEmote? = nil

    // Dancing (Apple Music)
    var isDancing: Bool = false
    var dancingLevel: CGFloat = 0   // 0→1 over 0.3s, 1→0 over 0.5s

    // Mini wandering look (random, ignores mouse)
    var miniLookTarget: CGPoint = .zero
    var miniLookNextTime: Double = 0

    // MARK: - Public API

    func setState(_ newState: BotState, force: Bool = false) {
        guard state != newState || force else { return }
        let prev = state
        state = newState
        cfg = BotStates[newState]!
        colT = cgColorToTuple(cfg.color)
        setTarget(key: "tint", value: cfg.tint)
        setTarget(key: "tilt", value: cfg.tilt)
        setBadge(cfg.badge)

        switch newState {
        case .finished:
            // Готово: Luna подпрыгивает, качнувшись, и роняет горсть звёздочек.
            anim("oy", keys: [
                TweenKey(target: -0.22, duration: 170, ease: Ease.out),
                TweenKey(target: 0.02,  duration: 190, ease: Ease.inOut),
                TweenKey(target: 0,     duration: 220, ease: Ease.back),
            ])
            anim("tilt", keys: [
                TweenKey(target: -0.2, duration: 160, ease: Ease.out),
                TweenKey(target: 0.16, duration: 260, ease: Ease.inOut),
                TweenKey(target: 0,    duration: 280, ease: Ease.inOut),
            ])
            physVy += 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.emit(.star, count: 4)
                self?.emit(.spark, count: 3)
            }
        case .error:
            // Ошибка: глаза гаснут, Luna оседает и вздрагивает едва заметной дрожью.
            anim("sy", keys: [
                TweenKey(target: 0.88, duration: 120, ease: Ease.out),
                TweenKey(target: 0.96, duration: 520, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 380, ease: Ease.inOut),
            ])
            anim("es", keys: [
                TweenKey(target: 0.78, duration: 150, ease: Ease.out),
                TweenKey(target: 1,    duration: 700, ease: Ease.inOut),
            ])
            anim("ox", keys: [
                TweenKey(target: 0.035,  duration: 55, ease: Ease.out),
                TweenKey(target: -0.035, duration: 70, ease: Ease.inOut),
                TweenKey(target: 0.02,   duration: 70, ease: Ease.inOut),
                TweenKey(target: 0,      duration: 110, ease: Ease.out),
            ])
        case .approval:
            // Просит ответа: два коротких подскока, как постукивание.
            anim("oy", keys: [
                TweenKey(target: -0.13, duration: 110, ease: Ease.out),
                TweenKey(target: 0,     duration: 120, ease: Ease.inOut),
                TweenKey(target: -0.09, duration: 100, ease: Ease.out),
                TweenKey(target: 0,     duration: 190, ease: Ease.back),
            ])
            anim("es", keys: [
                TweenKey(target: 1.14, duration: 140, ease: Ease.out),
                TweenKey(target: 1,    duration: 360, ease: Ease.inOut),
            ])
        case .dizzy:
            // Головокружение: один медленный оборот, потом качается, как маятник.
            doRoll(duration: 1500, turns: 1)
        case .question:
            // Вопрос: наклоняет голову сильнее, чем держит потом.
            anim("tilt", keys: [
                TweenKey(target: 0.3,  duration: 190, ease: Ease.out),
                TweenKey(target: 0.17, duration: 300, ease: Ease.inOut),
            ])
            blink()
        case .ratelimit:
            // Лимит: тяжело вздыхает — раздувается и сдувается.
            anim("sy", keys: [
                TweenKey(target: 1.06, duration: 480, ease: Ease.inOut),
                TweenKey(target: 0.97, duration: 520, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 300, ease: Ease.inOut),
            ])
            emit(.sweat, count: 1)
        default:
            if prev != .idle || newState != .idle { blink() }
        }
    }

    func setBadge(_ b: BadgeType?) {
        let key = badgeString(b)
        guard key != badgeKey else { return }
        badgeKey = key
        let tok = badgeToken + 1
        badgeToken = tok
        anim("badgeS", keys: [TweenKey(target: 0, duration: 90, ease: Ease.inOut)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, tok == self.badgeToken else { return }
            self.badge = b
            if b != nil {
                self.anim("badgeS", keys: [TweenKey(target: 1, duration: 280, ease: Ease.back)])
            }
        }
    }

    func blink() {
        guard !locks.contains("open") else { return }
        // Luna моргает неторопливо: веко опускается дольше, чем поднимается.
        anim("open", keys: [
            TweenKey(target: 0.08, duration: 95,  ease: Ease.inOut),
            TweenKey(target: 1,    duration: 170, ease: Ease.out),
        ])
    }

    func squash() {
        // Желе: сплющивается, вытягивается, оседает и успокаивается; украшения качаются следом.
        physVy += 0.9
        anim("sy", keys: [
            TweenKey(target: 0.8,  duration: 80,  ease: Ease.out),
            TweenKey(target: 1.12, duration: 140, ease: Ease.out),
            TweenKey(target: 0.97, duration: 120, ease: Ease.inOut),
            TweenKey(target: 1,    duration: 160, ease: Ease.inOut),
        ])
        anim("sx", keys: [
            TweenKey(target: 1.12, duration: 80,  ease: Ease.out),
            TweenKey(target: 0.92, duration: 140, ease: Ease.out),
            TweenKey(target: 1.02, duration: 120, ease: Ease.inOut),
            TweenKey(target: 1,    duration: 160, ease: Ease.inOut),
        ])
    }

    // MARK: - Gulp (mailbox swallow)

    func gulp() {
        // Open mouth wide for the swallow, then close during chewing
        slotHTarget = 0.42
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            self?.slotHTarget = 0
            self?.isChewing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { [weak self] in
                self?.isChewing = false
            }
        }
        // Глоток: сначала вытягивается, чтобы поймать письмо, потом оседает.
        anim("sy", keys: [
            TweenKey(target: 1.16, duration: 100, ease: Ease.out),
            TweenKey(target: 0.82, duration: 150, ease: Ease.out),
            TweenKey(target: 1.04, duration: 160, ease: Ease.inOut),
            TweenKey(target: 1,    duration: 200, ease: Ease.back),
        ])
        anim("sx", keys: [
            TweenKey(target: 0.86, duration: 100, ease: Ease.out),
            TweenKey(target: 1.22, duration: 150, ease: Ease.out),
            TweenKey(target: 0.97, duration: 160, ease: Ease.inOut),
            TweenKey(target: 1,    duration: 200, ease: Ease.back),
        ])
        physVy += 0.7
        blink()
    }

    // MARK: - Slap (dizzy mechanic)

    func slap() {
        interruptGreet()
        guard state != .dizzy else { return }
        let now = CACurrentMediaTime()
        slapTimes = slapTimes.filter { now - $0 < 1.7 }
        slapTimes.append(now)
        SoundEngine.shared.play("slap")
        squash()
        physVy -= 1.2
        let side: CGFloat = Bool.random() ? 1 : -1
        physVx += side * 0.9
        // Шлепок отбрасывает голову в сторону удара, и она возвращается с перекатом.
        anim("tilt", keys: [
            TweenKey(target: side * 0.24,  duration: 80,  ease: Ease.out),
            TweenKey(target: -side * 0.1,  duration: 160, ease: Ease.inOut),
            TweenKey(target: 0,            duration: 200, ease: Ease.inOut),
        ])
        if slapTimes.count >= 3 {
            slapTimes = []
            NotificationCenter.default.post(name: .botDizzy, object: nil)
        } else {
            // Annoyed: line eyes for 800ms, annoyed sound after 60ms delay
            eyeOverride = .line
            eyeOverrideUntil = now + 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SoundEngine.shared.play("annoyed")
            }
        }
    }

    // MARK: - Dancing

    func setDancing(_ dancing: Bool) {
        guard isDancing != dancing else { return }
        isDancing = dancing
    }

    // MARK: - Mini periodic behavior loop

    func doMiniBehaviorLoop() {
        switch permanentEmote {

        case .happy:
            // Два лёгких прыжка подряд, с поворотом головы на вершине
            guard !locks.contains("oy") else {
                miniNextBehavior = CACurrentMediaTime() + 0.4
                return
            }
            anim("oy", keys: [
                TweenKey(target: -0.24, duration: 150, ease: Ease.out),
                TweenKey(target:  0.02, duration: 170, ease: Ease.inOut),
                TweenKey(target: -0.12, duration: 110, ease: Ease.out),
                TweenKey(target:  0,    duration: 190, ease: Ease.back),
            ])
            anim("tilt", keys: [
                TweenKey(target:  0.14, duration: 180, ease: Ease.out),
                TweenKey(target: -0.1,  duration: 260, ease: Ease.inOut),
                TweenKey(target:  0,    duration: 190, ease: Ease.inOut),
            ])
            anim("sy", keys: [
                TweenKey(target: 0.86, duration: 70,  ease: Ease.out),
                TweenKey(target: 1.14, duration: 150, ease: Ease.out),
                TweenKey(target: 0.94, duration: 150, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 230, ease: Ease.back),
            ])
            miniNextBehavior = CACurrentMediaTime() + 2.6 + Double.random(in: 0...1.4)

        case .annoyed:
            // Сердитое «фух»: раздувается и дважды медленно качает головой
            guard !locks.contains("yaw") else {
                miniNextBehavior = CACurrentMediaTime() + 0.5
                return
            }
            anim("yaw", keys: [
                TweenKey(target: -0.5, duration: 140, ease: Ease.out),
                TweenKey(target:  0.5, duration: 220, ease: Ease.inOut),
                TweenKey(target: -0.3, duration: 200, ease: Ease.inOut),
                TweenKey(target:  0,   duration: 220, ease: Ease.out),
            ])
            anim("sx", keys: [
                TweenKey(target: 1.14, duration: 240, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 360, ease: Ease.inOut),
            ])
            miniNextBehavior = CACurrentMediaTime() + 3.4 + Double.random(in: 0...2.5)

        case .wink:
            // Подмигивает правым глазом и чуть приподнимается на цыпочки
            let now2 = CACurrentMediaTime()
            eyeOverride = .wink
            eyeOverrideUntil = now2 + 0.6
            anim("tilt", keys: [
                TweenKey(target:  0.2,  duration: 130, ease: Ease.out),
                TweenKey(target:  0.2,  duration: 300, ease: Ease.lin),
                TweenKey(target:  0,    duration: 220, ease: Ease.inOut),
            ])
            if !locks.contains("oy") {
                anim("oy", keys: [
                    TweenKey(target: -0.05, duration: 130, ease: Ease.out),
                    TweenKey(target:  0,    duration: 320, ease: Ease.inOut),
                ])
            }
            miniNextBehavior = CACurrentMediaTime() + 2.6 + Double.random(in: 0...2.0)

        case .love:
            // Сердечки и покачивание из стороны в сторону, как колыбель
            emit(.heart, count: 2)
            anim("tilt", keys: [
                TweenKey(target: -0.16, duration: 240, ease: Ease.out),
                TweenKey(target:  0.16, duration: 460, ease: Ease.inOut),
                TweenKey(target:  0,    duration: 280, ease: Ease.inOut),
            ])
            miniNextBehavior = CACurrentMediaTime() + 3.0 + Double.random(in: 0...1.5)

        default:
            miniNextBehavior = CACurrentMediaTime() + 3.0 + Double.random(in: 0...2.0)
        }
    }

    func doRoll(duration: CGFloat, turns: CGFloat) {
        roll = 0
        rollTurns = turns
        anim("roll", keys: [TweenKey(target: .pi * 2 * turns, duration: duration, ease: Ease.inOut)]) { [weak self] in
            guard let self else { return }
            self.roll = 0
            self.squash()
            if self.state == .dizzy {
                self.anim("tilt", keys: [
                    TweenKey(target: 0.22,  duration: 220, ease: Ease.out),
                    TweenKey(target: -0.16, duration: 300, ease: Ease.inOut),
                    TweenKey(target: 0.08,  duration: 260, ease: Ease.inOut),
                    TweenKey(target: 0,     duration: 260, ease: Ease.inOut),
                ])
            }
        }
    }

    func setOutfit(_ newOutfit: Outfit, animated: Bool = true) {
        guard newOutfit != outfitTarget else { return }
        outfitTarget = newOutfit
        tweens.removeValue(forKey: "outfitPresence")
        locks.remove("outfitPresence")
        if !animated {
            outfit = newOutfit
            outfitPresence = newOutfit != .none ? 1 : 0
        } else if newOutfit == .none {
            // Exit: fade out then clear outfit
            anim("outfitPresence", keys: [TweenKey(target: 0, duration: 180, ease: Ease.inOut)]) { [weak self] in
                self?.outfit = .none
            }
        } else if outfit == .none {
            // Enter: set outfit then animate in (Ease.back applied to position offsets in drawing code)
            outfit = newOutfit
            outfitPresence = 0
            anim("outfitPresence", keys: [TweenKey(target: 1, duration: 350, ease: Ease.inOut)]) { [weak self] in
                self?.squash()
            }
        } else {
            // Change: exit old, set new, enter
            anim("outfitPresence", keys: [TweenKey(target: 0, duration: 180, ease: Ease.inOut)]) { [weak self] in
                guard let self else { return }
                self.outfit = newOutfit
                self.anim("outfitPresence", keys: [TweenKey(target: 1, duration: 350, ease: Ease.inOut)]) { [weak self] in
                    self?.squash()
                }
            }
        }
    }

    func greet() {
        let now = CACurrentMediaTime()
        greetToken += 1
        let tok = greetToken
        waveStart = now + 0.55   // wave begins at 0.55s
        waveUntil = now + 1.7    // wave ends at 1.7s
        physVx += 0.35

        // 0s: happy eyes for full greeting (2s — no gap, no flicker)
        eyeOverride = .happy
        eyeOverrideUntil = now + 2.0
        // Лёгкий поклон: головой вперёд-вниз, потом выпрямляется.
        anim("oy", keys: [
            TweenKey(target:  0.04, duration: 160, ease: Ease.out),
            TweenKey(target: -0.1,  duration: 260, ease: Ease.out),
            TweenKey(target:  0.0,  duration: 240, ease: Ease.back),
        ])
        anim("tilt", keys: [
            TweenKey(target: -0.12, duration: 200, ease: Ease.out),
            TweenKey(target: -0.06, duration: 400, ease: Ease.inOut),
        ])

        // 0.3s: hands out + body squash + sound
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.anim("hands", keys: [TweenKey(target: 1, duration: 320, ease: Ease.out)])
            self.anim("sy", keys: [
                TweenKey(target: 0.93, duration: 110, ease: Ease.out),
                TweenKey(target: 1.0,  duration: 300, ease: Ease.back),
            ])
            self.anim("sx", keys: [
                TweenKey(target: 1.06, duration: 110, ease: Ease.out),
                TweenKey(target: 1.0,  duration: 300, ease: Ease.back),
            ])
            SoundEngine.shared.play("greet")
        }

        // 0.7s: first blink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.blink()
        }

        // 1.6s: second blink
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.blink()
        }

        // 1.7s: retract hands
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.waveUntil = 0
            self.anim("hands", keys: [TweenKey(target: 0, duration: 240, ease: Ease.inOut)])
            self.anim("tilt", keys: [TweenKey(target: 0, duration: 260, ease: Ease.inOut)])
        }

        // 1.85s: brief happy eyes then back to normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.85) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.eyeOverride = .happy
            self.eyeOverrideUntil = CACurrentMediaTime() + 0.30
        }
    }

    /// Immediately interrupts an in-progress greeting (hands retract in 150 ms).
    func interruptGreet() {
        guard hands > 0.01 || CACurrentMediaTime() < waveUntil else { return }
        greetToken += 1   // invalidate any pending closures
        waveUntil = 0
        waveStart = 0
        anim("hands", keys: [TweenKey(target: 0, duration: 150, ease: Ease.inOut)])
    }

    // MARK: - Listening mode

    /// Call when the island enters listening state (.voiceWoke).
    func enterListening() {
        isInListeningMode = true
        listeningHasWords  = false
        listeningPrevPermanentEmote = permanentEmote
        interruptGreet()

        // Привстаёт на цыпочки, как прислушиваясь
        anim("oy", keys: [
            TweenKey(target: -0.14, duration: 170, ease: Ease.out),
            TweenKey(target: -0.04, duration: 260, ease: Ease.inOut),
        ])
        squash()

        // Wide eyes — permanent (survive blinks)
        setPermanentEmote(.listening)

        // Head tilt held (no return-to-zero)
        anim("tilt", keys: [TweenKey(target: -0.10, duration: 200, ease: Ease.out)])

        // Show and raise right hand
        anim("hands",          keys: [TweenKey(target: 1,   duration: 150, ease: Ease.out)])
        anim("listenHandRaise",keys: [TweenKey(target: 1,   duration: 280, ease: Ease.out)])

        // Attentive sound
        SoundEngine.shared.play("question")

        // First slow blink sooner than normal
        nextBlink = CACurrentMediaTime() + 2.5 + Double.random(in: 0...1.0)
    }

    // MARK: - Voice in the compact island

    private var voicePrevPermanentEmote: BotEmote? = nil
    private(set) var isInVoiceCompact = false

    /// Current voice sub-state — set per frame by BotCanvasView from IslandWindowController signals.
    var voiceSubState: BotVoiceSubState = .none
    private var prevVoiceSubState: BotVoiceSubState = .none

    /// Voice session while the island stays compact (wake → answer spoken).
    /// One calm attentive pose for the whole exchange: wide eyes eased in, a slight
    /// tilt, no jump, no hands, no mic-driven motion — in the notch every extra
    /// movement reads as jitter.
    func enterVoiceCompact() {
        guard !isInVoiceCompact else { return }
        isInVoiceCompact = true
        voiceSubState = .none
        prevVoiceSubState = .none
        voicePrevPermanentEmote = permanentEmote
        setPermanentEmote(.listening)
        anim("es",   keys: [TweenKey(target: 1.06, duration: 260, ease: Ease.inOut)])
        anim("tilt", keys: [TweenKey(target: -0.06, duration: 260, ease: Ease.inOut)])
    }

    /// End of the voice exchange: back to the previous look, eased.
    func exitVoiceCompact() {
        guard isInVoiceCompact else { return }
        isInVoiceCompact = false
        voiceSubState = .none
        prevVoiceSubState = .none
        setPermanentEmote(voicePrevPermanentEmote)
        voicePrevPermanentEmote = nil
        anim("es",   keys: [TweenKey(target: 1, duration: 260, ease: Ease.inOut)])
        anim("tilt", keys: [TweenKey(target: 0, duration: 260, ease: Ease.inOut)])
    }

    /// Handle a voice sub-state transition: triggers the matching one-shot animations.
    /// Called from update() when voiceSubState changes.
    private func _applyVoiceSubStateTransition(_ sub: BotVoiceSubState) {
        switch sub {
        case .listening:
            // Back to attentive: gentle open eyes, tilt held
            anim("es",    keys: [TweenKey(target: 1.06, duration: 220, ease: Ease.inOut)])
            nextBlink = CACurrentMediaTime() + 2.0 + Double.random(in: 0...0.8)

        case .thinking:
            // Eyes glance up-right, squint slightly — "hmm"
            anim("es",    keys: [TweenKey(target: 0.86, duration: 280, ease: Ease.inOut)])
            nextBlink = CACurrentMediaTime() + 3.5 + Double.random(in: 0...1.0)

        case .speaking:
            // Joy squint, look forward, quick blink to mark the transition
            anim("es",    keys: [TweenKey(target: 0.72, duration: 200, ease: Ease.inOut)])
            nextBlink = CACurrentMediaTime() + 0.12  // blink right away (joy marker)

        case .none:
            break
        }
    }

    /// Call when the island leaves listening state.
    /// `hadCommand` = commandTranscript was non-empty when the session ended.
    func exitListening(hadCommand: Bool) {
        isInListeningMode = false
        listeningLevel    = 0
        listeningHasWords = false

        // Restore the permanent emote that was active before listening started
        setPermanentEmote(listeningPrevPermanentEmote)
        listeningPrevPermanentEmote = nil

        // Return head tilt to rest
        anim("tilt", keys: [TweenKey(target: 0, duration: 250, ease: Ease.inOut)])

        // Lower hand
        anim("listenHandRaise", keys: [TweenKey(target: 0, duration: 200, ease: Ease.inOut)])
        anim("hands",           keys: [TweenKey(target: 0, duration: 180, ease: Ease.inOut)])

        if hadCommand {
            // Nod
            anim("oy", keys: [
                TweenKey(target: -0.08, duration: 110, ease: Ease.out),
                TweenKey(target: 0,     duration: 200, ease: Ease.back),
            ])
            triggerEmote(.happy, duration: 1.0, silent: true)
        } else {
            // Shrug
            anim("sy", keys: [
                TweenKey(target: 0.93, duration: 180, ease: Ease.out),
                TweenKey(target: 1,    duration: 350, ease: Ease.back),
            ])
        }

        // Resume normal blink interval
        nextBlink = CACurrentMediaTime() + 1.5 + Double.random(in: 0...2)
    }

    /// Sets a permanent eye expression that survives blinks and transient emotes.
    func setPermanentEmote(_ emote: BotEmote?) {
        permanentEmote = emote
        // .wink fires periodically — don't freeze the eye (normal between winks)
        if emote == .wink {
            miniNextBehavior = CACurrentMediaTime() + Double.random(in: 0.8...2.5)
            return
        }
        permanentEye = emote.map { emoteEyeShape($0) }
        if let eye = permanentEye {
            eyeOverride = eye
            eyeOverrideUntil = .greatestFiniteMagnitude
        } else {
            if eyeOverrideUntil == .greatestFiniteMagnitude {
                eyeOverride = nil
                eyeOverrideUntil = 0
            }
        }
        // Stagger first periodic behavior so bots don't all fire at once
        miniNextBehavior = CACurrentMediaTime() + Double.random(in: 0.8...2.5)
    }

    func triggerEmote(_ emote: BotEmote, duration: Double = 1.8, silent: Bool = false) {
        let now = CACurrentMediaTime()
        eyeOverride = emoteEyeShape(emote)
        eyeOverrideUntil = now + duration

        switch emote {
        case .love:
            anim("blush", keys: [
                TweenKey(target: 1, duration: 300, ease: Ease.out),
                TweenKey(target: 1, duration: CGFloat((duration - 0.6) * 1000), ease: Ease.lin),
                TweenKey(target: 0, duration: 300, ease: Ease.inOut),
            ])
            emit(.heart, count: 4)
            anim("oy", keys: [
                TweenKey(target: -0.08, duration: 200, ease: Ease.out),
                TweenKey(target: 0,     duration: 380, ease: Ease.back),
            ])
            // Прижимает «ручки»: чуть сжимается и покачивается
            anim("sx", keys: [
                TweenKey(target: 0.94, duration: 220, ease: Ease.out),
                TweenKey(target: 1,    duration: 420, ease: Ease.back),
            ])
        case .surprised:
            // Удивление: отскакивает назад (вверх и в сторону), глаза огромные
            anim("oy", keys: [
                TweenKey(target: -0.36, duration: 120, ease: Ease.out),
                TweenKey(target: 0,     duration: 460, ease: Ease.back),
            ])
            anim("es", keys: [
                TweenKey(target: 1.35, duration: 110, ease: Ease.out),
                TweenKey(target: 1,    duration: 620, ease: Ease.inOut),
            ])
            physVx += 0.5
        case .proud:
            squash()
            emit(.star, count: 5)
            // Гордо задирает нос: наклон назад и вытягивается вверх
            anim("tilt", keys: [
                TweenKey(target: -0.18, duration: 260, ease: Ease.out),
                TweenKey(target: -0.18, duration: CGFloat((duration - 0.5) * 1000), ease: Ease.lin),
                TweenKey(target: 0,     duration: 300, ease: Ease.inOut),
            ])
            anim("blush", keys: [
                TweenKey(target: 0.7, duration: 250, ease: Ease.out),
                TweenKey(target: 0.7, duration: CGFloat((duration - 0.5) * 1000), ease: Ease.lin),
                TweenKey(target: 0,   duration: 300, ease: Ease.inOut),
            ])
        case .wink:
            anim("tilt", keys: [
                TweenKey(target: 0.12, duration: 160, ease: Ease.out),
                TweenKey(target: 0.12, duration: CGFloat((duration - 0.4) * 1000), ease: Ease.lin),
                TweenKey(target: 0,    duration: 240, ease: Ease.inOut),
            ])
        case .yawn:
            // Зевок: тянется вверх медленнее, чем раньше, и оседает
            anim("sy", keys: [
                TweenKey(target: 1.16, duration: 640, ease: Ease.inOut),
                TweenKey(target: 0.96, duration: 360, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 300, ease: Ease.inOut),
            ])
            anim("sx", keys: [
                TweenKey(target: 0.92, duration: 640, ease: Ease.inOut),
                TweenKey(target: 1.03, duration: 360, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 300, ease: Ease.inOut),
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.eyeOverride = .closed
                self?.emit(.z, count: 2)
            }
        case .happy:
            anim("blush", keys: [
                TweenKey(target: 0.6, duration: 200, ease: Ease.out),
                TweenKey(target: 0,   duration: 600, ease: Ease.inOut),
            ])
        case .annoyed:
            eyeOverride = .line
            eyeOverrideUntil = now + 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SoundEngine.shared.play("annoyed")
            }
        case .listening:
            // Attentive: slight head tilt + wide-open eyes
            anim("tilt", keys: [
                TweenKey(target: -0.07, duration: 180, ease: Ease.out),
                TweenKey(target: -0.07, duration: CGFloat((duration - 0.4) * 1000), ease: Ease.lin),
                TweenKey(target: 0,     duration: 240, ease: Ease.inOut),
            ])
            anim("es", keys: [
                TweenKey(target: 1.12, duration: 200, ease: Ease.out),
                TweenKey(target: 1,    duration: 500, ease: Ease.inOut),
            ])
        }
    }

    func emit(_ type: Particle.ParticleType, count: Int) {
        for i in 0..<count {
            let isZ = type == .z
            let p = Particle(
                type: type,
                x: (CGFloat.random(in: -0.5...0.5)) * 0.8 + (isZ ? 0.45 : 0),
                y: -0.85 - CGFloat.random(in: 0...0.2),
                vx: CGFloat.random(in: -0.5...0.5) * 0.35 + (isZ ? 0.18 : 0),
                vy: -(0.45 + CGFloat.random(in: 0...0.35)),
                age: -Double(i) * 0.14,
                life: 1.3 + Double.random(in: 0...0.5),
                rot: CGFloat.random(in: 0...(.pi * 2)),
                size: 0.15 + CGFloat.random(in: 0...0.08)
            )
            particles.append(p)
        }
    }

    // MARK: - Update (called every frame from TimelineView)

    func update(dt: Double) {
        let now = CACurrentMediaTime()
        let dtCG = CGFloat(dt)

        // Process tweens
        for key in tweens.keys {
            guard var tw = tweens[key] else { continue }
            let k = tw.keys[tw.keyIndex]
            let elapsed = now * 1000 - tw.startTime
            let p = min(1, max(0, CGFloat(elapsed) / k.duration))
            let val = tw.from + (k.target - tw.from) * k.ease(p)
            setProperty(key, value: val)

            if p >= 1 {
                tw.from = k.target
                tw.keyIndex += 1
                tw.startTime = now * 1000
                if tw.keyIndex >= tw.keys.count {
                    tweens.removeValue(forKey: key)
                    locks.remove(key)
                    tw.onComplete?()
                } else {
                    tweens[key] = tw
                }
            } else {
                tweens[key] = tw
            }
        }

        // Compute look targets
        let t = CGFloat(now - t0)
        var ty: CGFloat = lookX * 0.62
        var tp: CGFloat = lookY * 0.5

        if let fixedLook = cfg.look {
            ty = ty * 0.35 + fixedLook.x * 0.55
            tp = tp * 0.3  + fixedLook.y * 0.5
        }
        if cfg.scans {
            ty = sin(t * 2.6) * 0.6
            tp = -0.06
        }
        if state == .sleeping { ty = 0; tp = -0.14 }
        if state == .dizzy    { ty = sin(t * 9) * 0.25 }

        // Mini bots: override look with random wandering (never follows mouse)
        if isMini && cfg.look == nil && !cfg.scans && state != .sleeping && state != .dizzy {
            if now > miniLookNextTime {
                miniLookTarget = CGPoint(
                    x: CGFloat.random(in: -0.88...0.88),
                    y: CGFloat.random(in: -0.55...0.45)
                )
                miniLookNextTime = now + Double.random(in: 0.5...2.0)
            }
            ty = miniLookTarget.x * 0.62
            tp = miniLookTarget.y * 0.5
        }

        tgYaw   = ty
        tgPitch = tp
        tgTilt  = cfg.tilt

        // Listening mode: waiting sway + voice reactive
        if isInListeningMode {
            if !listeningHasWords {
                ty += sin(CGFloat(now - t0) * 1.1) * 0.06   // gentle waiting sway
                tp += -0.12                                    // look slightly upward
            }
            tgYaw   = ty
            tgPitch = tp
            if listeningLevel > 0.01 {
                let lvl = listeningLevel
                tgEs = max(tgEs, 1.0 + lvl * 0.15)
                if !locks.contains("sy") { tgSy = max(tgSy, 1.0 + lvl * 0.04) }
                if !locks.contains("sx") { tgSx = min(tgSx, 1.0 - lvl * 0.02) }
            }
        }

        // Voice compact sub-state: per-frame look and body targets
        if isInVoiceCompact {
            // Detect sub-state transitions and fire one-shot animations
            if voiceSubState != prevVoiceSubState {
                prevVoiceSubState = voiceSubState
                _applyVoiceSubStateTransition(voiceSubState)
            }

            switch voiceSubState {
            case .listening:
                // Mic-reactive eye pulse
                if listeningLevel > 0.01 {
                    let lvl = listeningLevel
                    tgEs = max(tgEs, 1.06 + lvl * 0.16)
                    if !locks.contains("sy") { tgSy = max(tgSy, 1.0 + lvl * 0.04) }
                }
            case .thinking:
                // Eyes drift slightly up-right (corner glance = "thinking")
                tgYaw   = ty + 0.12
                tgPitch = tp + 0.10
            case .speaking:
                // Gentle rhythmic bounce at ~3.5 Hz while speaking
                if !locks.contains("oy") {
                    let spkT = CGFloat(now - t0)
                    let bounce = sin(spkT * CGFloat.pi * 2 * 3.5) * 0.018
                    oy += (bounce - oy) * 0.25
                }
            case .none:
                break
            }
        }

        // Body sway during greeting wave
        if now > waveStart && now < waveUntil {
            let wt = CGFloat(now - waveStart)
            tgTilt = -0.06 + sin(2 * .pi * 1.2 * wt) * 0.07
        }

        // Подскоки с мягким приземлением: пик острее, чем у синусоиды
        let bounce = cfg.bounces ? -pow(abs(sin(t * 4.0)), 1.5) * 0.08 : CGFloat(0)
        // oy tween can override if not locked
        if !locks.contains("oy") { oy += (bounce - oy) * CGFloat(1 - pow(0.0008, dt)) }

        if cfg.breathes {
            // Сон: глубокое медленное дыхание (период около 6.6 с)
            let amp: CGFloat = isMini ? 0.08 : 0.05
            tgSy = 1 + sin(t * 0.95) * amp
            tgSx = 1 - sin(t * 0.95) * amp * 0.5
            if !isMini { tgTilt = cfg.tilt - 0.05 }   // голова чуть склонена
        } else if isMini {
            // Subtle idle pulse (unique phase per engine via t0)
            tgSy = 1 + sin(t * 1.7) * 0.05
            tgSx = 1 - sin(t * 1.7) * 0.025
        } else {
            // Покой: дышит еле заметно, период около 5 с
            tgSy = 1 + sin(t * 1.25) * 0.016
            tgSx = 1 - sin(t * 1.25) * 0.009
        }

        // Mini bots: periodic dramatic behaviors
        if isMini && now > miniNextBehavior {
            doMiniBehaviorLoop()
        }

        // Smooth look
        let kLook = CGFloat(1 - pow(0.004, dt))   // взгляд ленивее: Luna как будто сонная
        let kGen  = CGFloat(1 - pow(0.0008, dt))

        if !locks.contains("yaw")   { yaw   += (tgYaw   - yaw)   * kLook }
        if !locks.contains("pitch") { pitch += (tgPitch  - pitch) * kLook }
        if !locks.contains("tilt")  { tilt  += (tgTilt   - tilt)  * kGen  }
        if !locks.contains("sy")    { sy    += (tgSy     - sy)    * kGen  }
        if !locks.contains("sx")    { sx    += (tgSx     - sx)    * kGen  }
        if !locks.contains("es")    { es    += (tgEs     - es)    * kGen  }

        // Animate color
        col = mixColor(col, colT, 1 - pow(0.002, dt))

        // Blink
        if now > nextBlink {
            if state != .sleeping && state != .dizzy {
                blink()
                if Double.random(in: 0...1) < 0.16 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.blink() }
                }
            }
            nextBlink = now + (isInListeningMode ? 3.4 + Double.random(in: 0...1.5)
                                                 : 2.8 + Double.random(in: 0...3.6))
        }

        // Clear expired eye override (restore permanent if set)
        if eyeOverride != nil && now > eyeOverrideUntil {
            eyeOverride = permanentEye
            if permanentEye != nil { eyeOverrideUntil = .greatestFiniteMagnitude }
        }

        // Ambient particles
        if now - lastAmbient > 1.3 {
            lastAmbient = now
            if cfg.zz { emit(.z, count: 1) }   // ZZZ works for mini too
            if !isMini && cfg.sweat && Double.random(in: 0...1) < 0.5 { emit(.sweat, count: 1) }
        }

        // Age particles
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.life }

        // Mouth slot spring — ω₀ ≈ 25 rad/s (T=0.25s), ζ=0.6 (underdamped, slight clack)
        let slotOmega: CGFloat = 2 * .pi / 0.25
        let slotZeta: CGFloat = 0.6
        let slotAcc = slotOmega * slotOmega * (slotHTarget - slotH)
                    - 2 * slotZeta * slotOmega * slotHVel
        slotHVel += slotAcc * dtCG
        slotH = max(0, slotH + slotHVel * dtCG)

        // Dance level: fade in 0.3s, out 0.5s
        let dancingTarget: CGFloat = isDancing ? 1 : 0
        if dancingLevel < dancingTarget {
            dancingLevel = min(dancingTarget, dancingLevel + CGFloat(dt) / 0.3)
        } else if dancingLevel > dancingTarget {
            dancingLevel = max(dancingTarget, dancingLevel - CGFloat(dt) / 0.5)
        }

        // Phys spring for hat/pompom lag
        let yawVel  = (yaw  - prevYaw)  / CGFloat(dt)
        let oyVel   = (oy   - prevOy)   / CGFloat(dt)
        let rollVel = (roll - prevRoll) / CGFloat(dt)
        prevYaw = yaw; prevOy = oy; prevRoll = roll
        // Centrifugal physDx impulse when rigidly rolling with an outfit
        let centrifugal: CGFloat = (outfit != .none && outfitPresence > 0.05) ? rollVel * 0.18 : 0
        let tDx = max(-1, min(1, -yawVel * 0.35 - tilt * 2 + centrifugal))
        let tDy = max(-1, min(1,  oyVel  * 0.50))
        let stiff: CGFloat = 60, damp: CGFloat = 9
        physVx += (stiff * (tDx - physDx) - damp * physVx) * dtCG
        physVy += (stiff * (tDy - physDy) - damp * physVy) * dtCG
        physDx += physVx * dtCG
        physDy += physVy * dtCG

        lastTime = now
    }

    // MARK: - Dance transform

    /// Applies a 112-BPM dance bounce/sway around the bottom of the body.
    /// Call this on a copy of the GraphicsContext before the three draw passes.
    /// Luna танцует покачиваясь: наклон шире, прыжок ниже, чем у прежнего облика.
    func applyDance(_ ctx: inout GraphicsContext, size: CGSize) {
        guard dancingLevel > 0.001 else { return }
        let W = size.width, H = size.height, R = W * 0.3
        let px = W / 2 + ox * R
        let py = H / 2 + particleOverhang / 2 + oy * R + R * 0.06 + R * LunaLook.ryK
        let beat = CGFloat(CACurrentMediaTime()) * 112 / 60
        let hop = abs(sin(.pi * beat)), land = pow(1 - hop, 6), l = dancingLevel
        ctx.translateBy(x: px + 0.1 * R * sin(.pi * beat) * l, y: py - 0.16 * R * hop * l)
        ctx.rotate(by: .radians(0.15 * sin(.pi * beat) * l))
        ctx.scaleBy(x: 1 + 0.06 * land * l, y: 1 - 0.07 * land * l)
        ctx.translateBy(x: -px, y: -py)
    }

    // MARK: - Draw

    func draw(context: GraphicsContext, size: CGSize) {
        let W = size.width
        let H = size.height
        let R = W * 0.3
        let rx = R * LunaLook.rxK
        let ry = R * LunaLook.ryK

        let cx = W / 2 + ox * R
        // particleOverhang shifts the bot body down in canvas coords so hearts can fly into
        // the extended canvas above without clipping (BotPlacement compensates with position offset)
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06

        var ctx = context
        ctx.translateBy(x: cx, y: cy)
        if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
        ctx.scaleBy(x: sx, y: sy)

        // Украшения над головой: рисуются первыми, чтобы макушка тела закрывала их основание.
        drawCharm(ctx: ctx, R: R)

        // Body path (superellipse for Luna, morph to rect for upload)
        let bodyPath = mochiPath(rx: rx, ry: ry, morph: morph, R: R)

        // Body fill
        drawBody(ctx: &ctx, path: bodyPath, R: R, rx: rx, ry: ry,
                 pumpkinColors: outfit == .pumpkin && !isMini)

        // Blush — always shows a floor proportional to tint (prototype behaviour)
        let blushVal = max(blush, tint * 0.5) * (1 - morph)
        if blushVal > 0.01 {
            drawBlush(ctx: &ctx, path: bodyPath, rx: rx, ry: ry, R: R, blush: blushVal)
        }

        // Eyes
        drawEyes(ctx: &ctx, path: bodyPath, R: R, rx: rx, ry: ry)

        // Mouth hole — dark pill cutout inside the box face
        // Spec: left/right margins 0.10R, top margin 0.08R from box top (-0.94R)
        if morph > 0.05 {
            let hW = R * 1.80 * morph   // hole width = box width (2×1.0R) − 2×0.10R margin
            let hH = slotH * R * morph  // hole height (spring-animated, scaled by morph)
            let hX = -hW / 2
            // Hole Y: box top is -R*0.94 at morph=1, lerped from the egg's top at morph=0
            let boxTop = -R * lerp(LunaLook.ryK, 0.94, morph)
            let hY = boxTop + R * 0.08 * morph  // top margin scales with morph

            var boxCtx = ctx
            boxCtx.clip(to: bodyPath)  // everything clipped inside body

            // Top rim — 1pt white 55% line at box top edge
            var rim = Path()
            rim.move(to: CGPoint(x: -R * 0.90 * morph, y: boxTop + 1))
            rim.addLine(to: CGPoint(x: R * 0.90 * morph, y: boxTop + 1))
            boxCtx.stroke(rim, with: .color(Color.white.opacity(0.55 * Double(morph))),
                          style: StrokeStyle(lineWidth: 1, lineCap: .round))

            // Hole interior — only draw if visibly open
            if hH > 0.8 {
                let hR = min(hW / 2, hH / 2)  // fully rounded when hH < hW (pill shape)
                var hole = Path()
                hole.addRoundedRect(in: CGRect(x: hX, y: hY, width: hW, height: hH),
                                    cornerSize: CGSize(width: hR, height: hR))
                boxCtx.fill(hole, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.027, green: 0.031, blue: 0.039),
                                      Color(red: 0.063, green: 0.075, blue: 0.102)]),
                    startPoint: CGPoint(x: 0, y: hY),
                    endPoint: CGPoint(x: 0, y: hY + hH)
                ))
                // Bottom lip — 1pt white 28% highlight
                if hH > 4 {
                    let lipR = min(hR, (hW - 2) / 2)
                    var lip = Path()
                    lip.move(to: CGPoint(x: hX + lipR, y: hY + hH - 0.5))
                    lip.addLine(to: CGPoint(x: hX + hW - lipR, y: hY + hH - 0.5))
                    boxCtx.stroke(lip, with: .color(Color.white.opacity(0.28 * Double(morph))),
                                  style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            }
        }

        // Reset transform for hands, badge, particles which need world coords
        // (We'll pass world-space cx/cy to these helpers)
    }

    // MARK: - Draw hands behind body (called before draw() so hands appear under Luna)

    func drawHandsBehind(context: GraphicsContext, size: CGSize) {
        guard hands > 0.01, !isMini else { return }
        let W = size.width, H = size.height
        let R = W * 0.3
        // Only draw hands when Luna is large enough to be meaningful (not compact/peek)
        guard R > 14 else { return }
        let rx = R * LunaLook.rxK
        let ry = R * LunaLook.ryK
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06

        let now = CACurrentMediaTime()
        let bodyH = 2 * ry   // full body height

        // Ручка-варежка: чуть выше, чем шире (0.24 и 0.30 высоты тела), растёт вместе с hands
        let hew = 0.24 * ry * hands   // half-width
        let heh = 0.30 * ry * hands   // half-height

        // Body half-dims with current squash scale
        let hwB = rx * sx
        let hhB = ry * sy

        let isWaving = now >= waveStart && waveStart > 0 && now < waveUntil

        for sd in [-1.0, 1.0] {
            var localX: CGFloat
            var localY: CGFloat
            var handRot: CGFloat = 0

            if sd > 0 && isWaving {
                // Right hand: rise to wave position over first 180ms, then oscillate
                let wt = CGFloat(now - waveStart)
                let rise = min(1.0, wt / 0.24)
                let riseEased: CGFloat = 1 - pow(1 - rise, 3)   // easeOut cubic

                // Rest position is lower-side; wave position is upper-side (at eye height)
                let restX: CGFloat = hwB * 1.08
                let restY: CGFloat = hhB * 0.70
                // Машет медленнее (9 рад/с вместо 13), широкой дугой
                let oscX = cos(9 * wt) * 0.08 * bodyH
                let oscY = -sin(9 * wt) * 0.12 * bodyH
                let waveX: CGFloat = hwB * 1.12 + oscX
                let waveY: CGFloat = -hhB * 0.2 + oscY
                localX = restX + (waveX - restX) * riseEased
                localY = restY + (waveY - restY) * riseEased
                handRot = (-0.5 + sin(9 * wt) * 0.4) * riseEased

            } else if sd < 0 && isWaving {
                // Left hand: gentle sway at rest position
                let wt = CGFloat(now - waveStart)
                localX = -hwB * 1.08
                localY = hhB * 0.70 + sin(4.5 * wt) * 0.04 * bodyH

            } else if sd > 0 && listenHandRaise > 0.01 {
                // Right hand: raised to attentive listening position (not waving)
                let h = listenHandRaise
                localX = lerp(hwB * 1.08, hwB * 1.05, h)
                localY = lerp(hhB * 0.70, -hhB * 0.28, h)
                handRot = -0.45 * h   // tilts slightly toward head

            } else {
                // Rest: lower-side, clearly peeking behind body bottom
                localX = CGFloat(sd) * hwB * 1.08
                localY = hhB * 0.70
            }

            // Apply body tilt to get world position
            let cosT = cos(tilt), sinT = sin(tilt)
            let worldX = cx + cosT * localX - sinT * localY
            let worldY = cy + sinT * localX + cosT * localY

            // Draw
            var handCtx = context
            handCtx.translateBy(x: worldX, y: worldY)
            if handRot != 0 { handCtx.rotate(by: .radians(handRot)) }

            // Варежка: скруглённый квадрат, а не овал. Тело — ночное, по краю контур света.
            let handPath = Path(LunaLook.superellipse(rx: hew, ry: heh, exponent: 3.2, steps: 40))
            let c0: Color, c1: Color
            if let bc = bodyColor {
                c0 = colorFromTuple(mix3(cgColorToTuple(bc), (1, 1, 1), 0.35))
                c1 = colorFromTuple(cgColorToTuple(bc))
            } else {
                c0 = colorFromTuple(cgColorToTuple(MochiConst.baseTop))
                c1 = colorFromTuple(cgColorToTuple(MochiConst.baseBottom))
            }
            handCtx.fill(handPath, with: .linearGradient(
                Gradient(colors: [c0, c1]),
                startPoint: CGPoint(x: hew * 0.7, y: -heh * 0.85),
                endPoint: CGPoint(x: -hew * 0.8, y: heh * 0.9)
            ))
            if bodyColor == nil {
                // Контур света и звёздочка на ладони
                let rim = Color(red: LunaLook.rim.r, green: LunaLook.rim.g, blue: LunaLook.rim.b)
                handCtx.stroke(handPath, with: .color(rim.opacity(0.55)), lineWidth: 1)
                if heh > 3 {
                    handCtx.fill(Path(LunaLook.sparkle(outer: heh * 0.34)),
                                 with: .color(rim.opacity(0.7)))
                }
            } else {
                handCtx.stroke(handPath, with: .color(Color.black.opacity(0.08)), lineWidth: 1)
            }
        }
    }

    func drawHandsAndExtras(context: GraphicsContext, size: CGSize) {
        let W = size.width
        let H = size.height
        let R = W * 0.3
        let rx = R * LunaLook.rxK
        let ry = R * LunaLook.ryK
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06

        // Badge — hidden while morphing to mailbox
        if let badge = badge, badgeS > 0.01, morph < 0.25 {
            drawBadge(context: context, size: size, badge: badge, R: R, rx: rx, ry: ry, cx: cx, cy: cy)
        }

        // Particles
        drawParticles(context: context, size: size, R: R, cx: cx, cy: cy)
    }

    func drawOutfitBehind(context: GraphicsContext, size: CGSize) {
        guard outfit != .none, !isMini else { return }
        let W = size.width, H = size.height, R = W * 0.3
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06
        // Rigid roll: accessories see roll=0 (they rotate with the body via context transform)
        let outfitRoll: CGFloat = outfitPresence > 0.05 ? 0 : roll
        let mH = MochiH(R: R, yaw: yaw, pitch: pitch, physDx: physDx, physDy: physDy, roll: outfitRoll)
        drawOutfitBehindStatic(context: context, outfit: outfit, H: mH,
                               cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                               roll: outfitRoll, morph: morph, isMini: isMini,
                               presence: outfitPresence, rollTurns: rollTurns)
    }

    func drawOutfitFront(context: GraphicsContext, size: CGSize) {
        guard outfit != .none, !isMini else { return }
        let W = size.width, H = size.height, R = W * 0.3
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06
        // Rigid roll: accessories see roll=0 (they rotate with the body via context transform)
        let outfitRoll: CGFloat = outfitPresence > 0.05 ? 0 : roll
        let mH = MochiH(R: R, yaw: yaw, pitch: pitch, physDx: physDx, physDy: physDy, roll: outfitRoll)
        drawOutfitFrontStatic(context: context, outfit: outfit, H: mH,
                              cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                              roll: outfitRoll, morph: morph, isMini: isMini,
                              presence: outfitPresence, rollTurns: rollTurns)
    }

    /// World-space center of Luna's body (used by BotCanvasView for rigid-roll transform)
    func bodyCenter(size: CGSize) -> CGPoint {
        let W = size.width, R = W * 0.3
        let cx = W / 2 + ox * R
        let cy = size.height / 2 + particleOverhang / 2 + oy * R + R * 0.06
        return CGPoint(x: cx, y: cy)
    }

    var outfitFollowsRoll: Bool {
        switch outfit {
        case .sunglasses, .roundGlasses, .bow, .scarf, .pumpkin: return true
        default: return false
        }
    }

    // MARK: - Private draw helpers

    private func mochiPath(rx: CGFloat, ry: CGFloat, morph: CGFloat, R: CGFloat) -> Path {
        let n = 72
        let expN: CGFloat = 2.0 / LunaLook.exponent
        // Target mailbox dims (spec: 1.0R wide, 0.94R tall, 0.42R corner radius)
        let tw = R * 1.0
        let th = R * 0.94
        let tr = R * 0.42
        var path = Path()
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * .pi * 2
            let ca = cos(a), sa = sin(a)
            let px0 = rx * (ca >= 0 ? pow(ca, expN) : -pow(-ca, expN))
            let py0 = ry * (sa >= 0 ? pow(sa, expN) : -pow(-sa, expN))
            let px: CGFloat
            let py: CGFloat
            if morph < 0.005 {
                px = px0; py = py0
            } else {
                let rr = rrPoint(ca: ca, sa: sa, W: tw, H: th, cr: tr)
                px = lerp(px0, rr.x, morph)
                py = lerp(py0, rr.y, morph)
            }
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        return path
    }

    /// Ray-rounded-rect intersection: find the point on the rounded rect boundary in direction (ca, sa).
    private func rrPoint(ca: CGFloat, sa: CGFloat, W: CGFloat, H: CGFloat, cr: CGFloat) -> CGPoint {
        let eps: CGFloat = 1e-6
        let kx: CGFloat = ca >= 0 ? 1 : -1
        let ky: CGFloat = sa >= 0 ? 1 : -1
        let cx = kx * (W - cr)
        let cy = ky * (H - cr)

        // Try corner arc
        let dot  = ca * cx + sa * cy
        let disc = dot * dot - (cx*cx + cy*cy - cr*cr)
        if disc >= 0 {
            let t = dot + sqrt(disc)
            if t > eps {
                let px = ca * t, py = sa * t
                if abs(px) >= W - cr - eps && abs(py) >= H - cr - eps {
                    return CGPoint(x: px, y: py)
                }
            }
        }

        // Horizontal edge |y| = H
        if abs(sa) > eps {
            let t = (ky * H) / sa
            if t > eps {
                let x = ca * t
                if abs(x) <= W - cr + eps { return CGPoint(x: x, y: ky * H) }
            }
        }
        // Vertical edge |x| = W
        if abs(ca) > eps {
            let t = (kx * W) / ca
            if t > eps {
                let y = sa * t
                if abs(y) <= H - cr + eps { return CGPoint(x: kx * W, y: y) }
            }
        }

        return CGPoint(x: kx * W, y: ky * H)
    }

    /// Полумесяц и звёздочка над головой. Качаются с запаздыванием за телом (`physDx/physDy`),
    /// сдвигаются от поворота головы и исчезают под шапкой, в мини-версии и при превращении в ящик.
    private func drawCharm(ctx: GraphicsContext, R: CGFloat) {
        guard !isMini, R > 8, morph < 0.05 else { return }
        var alpha: CGFloat = 1
        if outfit.coversHead { alpha = 1 - min(1, outfitPresence * 1.6) }
        guard alpha > 0.01 else { return }

        let ch = LunaLook.charm(R: R)
        let lagX = physDx * R * 0.12 + sin(yaw) * R * 0.18
        let lagY = physDy * R * 0.06
        var c = ctx
        c.opacity = Double(alpha)
        c.translateBy(x: lagX, y: lagY)
        // Подвеска качается вокруг основания: при наклоне головы отстаёт от неё.
        c.rotate(by: .radians(Double(physDx * 0.18)))
        let color = Color(red: LunaLook.charm.r, green: LunaLook.charm.g, blue: LunaLook.charm.b)
        let moon = Path(LunaLook.moonPath(ch))
        let star = Path(LunaLook.starPath(ch))
        c.stroke(moon, with: .color(color.opacity(0.18)),
                 style: StrokeStyle(lineWidth: R * 0.1, lineJoin: .round))
        c.fill(moon, with: .color(color))
        // Звёздочка мерцает: пульс размера дважды в 3 секунды.
        let tw = 1 + 0.12 * sin(CGFloat(CACurrentMediaTime() - t0) * 2.1)
        var s = c
        s.translateBy(x: ch.starCenter.x, y: ch.starCenter.y)
        s.scaleBy(x: tw, y: tw)
        s.translateBy(x: -ch.starCenter.x, y: -ch.starCenter.y)
        s.fill(star, with: .color(color))
    }

    private func drawBody(ctx: inout GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat,
                          pumpkinColors: Bool = false) {
        if let bc = bodyColor, !pumpkinColors {
            // Mini bots: flat solid fill — no gradient, no reflection, no highlight
            ctx.fill(path, with: .color(Color(cgColor: bc)))
        } else {
            // Main bot: linear gradient body
            let top: Color = pumpkinColors ? Color(hex: "#FFA94D")
                : colorFromTuple((LunaLook.bodyTop.r, LunaLook.bodyTop.g, LunaLook.bodyTop.b))
            let bot: Color = pumpkinColors ? Color(hex: "#E8590C")
                : colorFromTuple((LunaLook.bodyBottom.r, LunaLook.bodyBottom.g, LunaLook.bodyBottom.b))
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [top, bot]),
                startPoint: CGPoint(x: rx*0.7, y: -ry*0.85),
                endPoint: CGPoint(x: -rx*0.8, y: ry*0.9)
            ))
            // State tint — fades out as morph increases (mailbox has no tint)
            let effectiveTint = tint * (1 - morph)
            if effectiveTint > 0.01 {
                let tc = colorFromTuple(col)
                if pumpkinColors {
                    ctx.fill(path, with: .linearGradient(
                        Gradient(stops: [
                            .init(color: tc.opacity(Double(0.72 * effectiveTint)), location: 0),
                            .init(color: tc.opacity(0), location: 1)
                        ]),
                        startPoint: CGPoint(x: 0, y: ry),
                        endPoint: CGPoint(x: 0, y: -ry)
                    ))
                } else {
                    // На тёмном теле заливка грязнила бы цвет: состояние светится по краю,
                    // середина (там глаза) остаётся тёмной и читаемой.
                    let a = Double(min(1, effectiveTint * 1.25))
                    ctx.fill(path, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: tc.opacity(0), location: 0),
                            .init(color: tc.opacity(0), location: 0.4),
                            .init(color: tc.opacity(a), location: 1)
                        ]),
                        center: .zero, startRadius: 0, endRadius: ry * 1.02
                    ))
                    ctx.fill(path, with: .linearGradient(
                        Gradient(stops: [
                            .init(color: tc.opacity(0.4 * Double(effectiveTint)), location: 0),
                            .init(color: tc.opacity(0), location: 1)
                        ]),
                        startPoint: CGPoint(x: 0, y: ry),
                        endPoint: CGPoint(x: 0, y: ry * 0.1)
                    ))
                }
            }
            // Shadow rim
            ctx.fill(path, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.6),
                    .init(color: Color.black.opacity(0.2), location: 1)
                ]),
                center: .zero, startRadius: R*0.15, endRadius: R*1.25
            ))
            // Лунный блик: слева сверху, холодный
            ctx.fill(path, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.86, green: 0.9, blue: 1).opacity(pumpkinColors ? 0.5 : 0.36), location: 0),
                    .init(color: .clear, location: 1)
                ]),
                center: CGPoint(x: -rx*0.36, y: -ry*0.5),
                startRadius: 0,
                endRadius: R*0.4
            ))
            if !pumpkinColors && morph < 0.05 {
                // Звёздная пыль на брюшке; от поворота головы смещается внутри тела
                var cc = ctx
                cc.clip(to: path)
                let par = sin(yaw) * rx * 0.3
                let dust = Color(red: LunaLook.glow.r, green: LunaLook.glow.g, blue: LunaLook.glow.b)
                let fade = Double(1 - min(1, effectiveTint * 0.8))
                for (dx, dy, r, a) in [(-0.46, 0.62, 0.045, 0.55), (0.5, 0.44, 0.032, 0.45), (0.1, 0.82, 0.028, 0.4)]
                    as [(CGFloat, CGFloat, CGFloat, Double)] {
                    var e = Path()
                    e.addEllipse(in: CGRect(x: dx * rx + par - r * R, y: dy * ry - r * R, width: r * R * 2, height: r * R * 2))
                    cc.fill(e, with: .color(dust.opacity(a * fade)))
                }
            }
        }
    }

    private func drawBlush(ctx: inout GraphicsContext, path: Path, rx: CGFloat, ry: CGFloat, R: CGFloat, blush: CGFloat) {
        ctx.clip(to: path)
        let yOffset = sin(yaw) * rx * 0.6
        for sd in [-1.0, 1.0] {
            // Щёчки ниже глаз и ближе к краю: глаза у малыша сидят низко
            let bx = CGFloat(sd) * rx * 0.58 + yOffset
            let by = ry * 0.56
            var ellipse = Path()
            ellipse.addEllipse(in: CGRect(x: bx - R*0.17, y: by - R*0.1, width: R*0.34, height: R*0.2))
            ctx.fill(ellipse, with: .color(Color(red: LunaLook.blush.r, green: LunaLook.blush.g,
                                                 blue: LunaLook.blush.b, opacity: Double(0.5 * blush))))
        }
    }

    /// Каким цветом рисовать глаза на текущем теле и светятся ли они.
    private var eyeInk: (color: Color, glows: Bool) {
        let dark = Color(cgColor: isMini ? MochiConst.miniInk : MochiConst.ink)
        let glow = Color(cgColor: MochiConst.glow)
        if outfit == .pumpkin && !isMini { return (dark, false) }
        if let bc = bodyColor {
            let c = cgColorToTuple(bc)
            let lum = LunaLook.luminance((c.0, c.1, c.2))
            return lum < LunaLook.darkInkThreshold ? (glow, true) : (dark, false)
        }
        return (glow, true)
    }

    private func drawEyes(ctx: inout GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        var shape = eyeOverride ?? cfg.eye
        // Dance: happy eyes in calm states
        if isDancing && dancingLevel > 0.15 && !isMini && (state == .idle || state == .finished) {
            shape = .happy
        }
        // In box mode: cup eyes when file over box (slotHTarget set), happy arcs while chewing
        if morph > 0.5 {
            if isChewing { shape = .happy }
            else if slotHTarget > 0.05 || slotH > 0.10 { shape = .cup }
        }
        ctx.clip(to: path)

        // Build eye frames: use mEyeFrames for position/foreshortening, but keep roll in eyePitch
        // When an outfit is rigidly rotating, the whole body turns — eyes do NOT add roll
        let rigidRoll = outfit != .none && outfitPresence > 0.05
        let mH = MochiH(R: R, yaw: yaw, pitch: pitch)
        let (ink, glows) = eyeInk
        for f in mEyeFrames(mH) {
            // Re-derive pitch with roll for the roll-through effect (illusion, outfit=none only)
            var eyePitch = MochiConst.eyeP + pitch + (rigidRoll ? 0 : roll)
            eyePitch = ((eyePitch + .pi).truncatingRemainder(dividingBy: .pi*2) + .pi*2).truncatingRemainder(dividingBy: .pi*2) - .pi
            let cp = cos(eyePitch)
            let eyeYaw = f.sd * MochiConst.eyeSp + yaw
            guard cos(eyeYaw) * cp > 0.04 else { continue }

            let ey = f.y + (morph > 0 ? ry * 0.14 * morph : 0)
            let fx = lerp(f.fx, 1, morph * 0.7)
            let fy = lerp(f.fy, 1, morph * 0.7)

            let eyeMult: CGFloat = isMini ? 1.7 : 1.0
            let ew = R * MochiConst.eyeW * es * eyeMult
            let eh = R * MochiConst.eyeH * es * eyeMult

            var eyeCtx = ctx
            eyeCtx.translateBy(x: f.x, y: ey)
            eyeCtx.scaleBy(x: fx, y: fy)
            let g = LunaFace.glyph(shape, w: ew, h: eh, open: open, sd: f.sd,
                                   time: CGFloat(CACurrentMediaTime()))
            LunaFace.render(g, in: &eyeCtx, ink: ink, halo: glows && !isMini ? ew * 0.3 : 0)
        }
    }

    private func drawBadge(context: GraphicsContext, size: CGSize, badge: BadgeType, R: CGFloat, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) {
        let bs = badgeS * (isMini ? 1.25 : 1)
        let bx = cx - R * 0.64 * sx
        let by = cy - R * 0.76 * sy
        var ctx = context
        ctx.translateBy(x: bx, y: by)
        ctx.scaleBy(x: bs, y: bs)
        let now = CGFloat(CACurrentMediaTime())

        switch badge {
        case .dots(let col):
            if isMini {
                // Mini: animated pulsing dot
                let phase = (now * 2.4).truncatingRemainder(dividingBy: 1)
                let dotR = R * 0.22 * (1 + 0.25 * sin(phase * .pi * 2))
                var outer = Path()
                outer.addEllipse(in: CGRect(x: -R*0.2, y: -R*0.2, width: R*0.4, height: R*0.4))
                ctx.fill(outer, with: .color(.black))
                var dot = Path()
                dot.addEllipse(in: CGRect(x: -dotR, y: -dotR, width: dotR*2, height: dotR*2))
                ctx.fill(dot, with: .color(Color(cgColor: col)))
            } else {
                // Pill badge with animated dots (prototype style)
                let pw: CGFloat = R * 0.72
                let ph: CGFloat = R * 0.36
                var pill = Path()
                pill.addRoundedRect(in: CGRect(x: -pw/2, y: -ph/2, width: pw, height: ph),
                                    cornerSize: CGSize(width: ph/2, height: ph/2))
                ctx.fill(pill, with: .color(Color(cgColor: col)))
                for i in 0..<3 {
                    let phase = ((now * 2.4 - CGFloat(i) * 0.22).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                    let dotR = R * 0.055 * (1 + 0.4 * max(0, sin(phase * .pi * 2)))
                    var dot = Path()
                    dot.addEllipse(in: CGRect(x: (CGFloat(i)-1)*R*0.18 - dotR, y: -dotR, width: dotR*2, height: dotR*2))
                    ctx.fill(dot, with: .color(.white))
                }
            }

        case .bang(let col), .question(let col):
            var ring = Path()
            ring.addEllipse(in: CGRect(x: -R*0.3, y: -R*0.3, width: R*0.6, height: R*0.6))
            ctx.fill(ring, with: .color(.black))
            var inner = Path()
            inner.addEllipse(in: CGRect(x: -R*0.23, y: -R*0.23, width: R*0.46, height: R*0.46))
            ctx.fill(inner, with: .color(Color(cgColor: col)))
            if !isMini {
                let text = badge == .bang(col) ? "!" : "?"
                ctx.draw(Text(text).font(.system(size: R*0.32, weight: .black)).foregroundColor(.white),
                         at: CGPoint(x: 0, y: R*0.02))
            }

        case .dot(let col):
            var outer = Path()
            outer.addEllipse(in: CGRect(x: -R*0.2, y: -R*0.2, width: R*0.4, height: R*0.4))
            ctx.fill(outer, with: .color(.black))
            var inner = Path()
            inner.addEllipse(in: CGRect(x: -R*0.135, y: -R*0.135, width: R*0.27, height: R*0.27))
            ctx.fill(inner, with: .color(Color(cgColor: col)))
        }
    }

    private func drawParticles(context: GraphicsContext, size: CGSize, R: CGFloat, cx: CGFloat, cy: CGFloat) {
        for p in particles {
            guard p.age > 0 else { continue }
            let k = CGFloat(p.age / p.life)
            let a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8
            let px = cx + (p.x + p.vx * CGFloat(p.age)) * R * 1.3
            let py = cy + (p.y + p.vy * CGFloat(p.age)) * R * 1.3
            let sz = R * p.size * (1 + k * 0.4)

            var pctx = context
            pctx.translateBy(x: px, y: py)
            pctx.opacity = Double(min(max(a, 0), 1))

            switch p.type {
            case .heart:
                pctx.rotate(by: .radians(sin(CGFloat(p.age) * 6) * 0.3))
                pctx.fill(heartShape(size: sz), with: .color(Color(hex: "#FF4D6D")))
            case .star:
                pctx.rotate(by: .radians(p.rot + CGFloat(p.age) * 2))
                pctx.fill(starShape(outer: sz, inner: sz*0.45), with: .color(Color(hex: "#F7B32B")))
            case .spark:
                pctx.rotate(by: .radians(p.rot))
                pctx.fill(starShape(outer: sz*0.8, inner: sz*0.18), with: .color(.white))
            case .sweat:
                var drop = Path()
                drop.move(to: CGPoint(x: 0, y: -sz))
                drop.addQuadCurve(to: CGPoint(x: 0, y: sz*0.6), control: CGPoint(x: sz*0.8, y: sz*0.2))
                drop.addQuadCurve(to: CGPoint(x: 0, y: -sz), control: CGPoint(x: -sz*0.8, y: sz*0.2))
                pctx.fill(drop, with: .color(Color(hex: "#7CC7FF")))
            case .z:
                pctx.draw(Text("z").font(.system(size: sz*1.9, weight: .bold)).foregroundColor(Color(red: 0.82, green: 0.86, blue: 0.92)),
                          at: .zero)
            }
        }
    }

    // MARK: - Tween helpers

    func anim(_ key: String, keys: [TweenKey], onComplete: (() -> Void)? = nil) {
        let current = getProperty(key)
        tweens[key] = Tween(property: key, keys: keys, keyIndex: 0,
                            from: current, startTime: CACurrentMediaTime() * 1000,
                            onComplete: onComplete)
        locks.insert(key)
    }

    private func setTarget(key: String, value: CGFloat) {
        guard !locks.contains(key) else { return }
        switch key {
        case "tint":  tint  += (value - tint)  // immediate target, smoothed in update
        case "tilt":  tgTilt = value
        default: break
        }
    }

    private func setProperty(_ key: String, value: CGFloat) {
        switch key {
        case "yaw":           yaw           = value
        case "pitch":         pitch         = value
        case "roll":          roll          = value
        case "tilt":          tilt          = value
        case "open":          open          = value
        case "sx":            sx            = value
        case "sy":            sy            = value
        case "oy":            oy            = value
        case "ox":            ox            = value
        case "tint":          tint          = value
        case "morph":         morph         = value
        case "hands":         hands         = value
        case "blush":         blush         = value
        case "es":            es            = value
        case "badgeS":        badgeS        = value
        case "outfitPresence": outfitPresence = value
        case "listenHandRaise": listenHandRaise = value
        default: break
        }
    }

    private func getProperty(_ key: String) -> CGFloat {
        switch key {
        case "yaw":           return yaw
        case "pitch":         return pitch
        case "roll":          return roll
        case "tilt":          return tilt
        case "open":          return open
        case "sx":            return sx
        case "sy":            return sy
        case "oy":            return oy
        case "ox":            return ox
        case "tint":          return tint
        case "morph":         return morph
        case "hands":         return hands
        case "blush":         return blush
        case "es":            return es
        case "badgeS":        return badgeS
        case "outfitPresence": return outfitPresence
        case "listenHandRaise": return listenHandRaise
        default:              return 0
        }
    }
}

// MARK: - Math helpers

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b-a) * t }
private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

private func cgColorToTuple(_ c: CGColor) -> (CGFloat, CGFloat, CGFloat) {
    guard let comps = c.components, comps.count >= 3 else { return (1,1,1) }
    return (comps[0], comps[1], comps[2])
}

private func mix3(_ a: (CGFloat,CGFloat,CGFloat), _ b: (CGFloat,CGFloat,CGFloat), _ t: CGFloat) -> (CGFloat,CGFloat,CGFloat) {
    (lerp(a.0,b.0,t), lerp(a.1,b.1,t), lerp(a.2,b.2,t))
}

private func mixColor(_ a: (CGFloat,CGFloat,CGFloat), _ b: (CGFloat,CGFloat,CGFloat), _ t: CGFloat) -> (CGFloat,CGFloat,CGFloat) {
    mix3(a, b, t)
}

private func colorFromTuple(_ t: (CGFloat,CGFloat,CGFloat)) -> Color {
    Color(red: Double(t.0), green: Double(t.1), blue: Double(t.2))
}

private func badgeString(_ b: BadgeType?) -> String {
    guard let b else { return "none" }
    func hex(_ c: CGColor) -> String {
        guard let k = c.components, k.count >= 3 else { return "?" }
        return "\(Int(k[0]*255)).\(Int(k[1]*255)).\(Int(k[2]*255))"
    }
    switch b {
    case .dots(let c):     return "dots-\(hex(c))"
    case .bang(let c):     return "bang-\(hex(c))"
    case .question(let c): return "q-\(hex(c))"
    case .dot(let c):      return "dot-\(hex(c))"
    }
}

private func emoteEyeShape(_ e: BotEmote) -> EyeShape {
    switch e {
    case .love:      return .heart
    case .surprised: return .dot
    case .proud:     return .star
    case .wink:      return .wink
    case .yawn:      return .tired
    case .happy:     return .happy
    case .annoyed:   return .line
    case .listening: return .wide
    }
}

// MARK: - Shape helpers

private func heartShape(size s: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 0, y: s * 0.38))
    p.addCurve(to: CGPoint(x: 0, y: -s * 0.38),
               control1: CGPoint(x: -s * 1.05, y: -s * 0.15),
               control2: CGPoint(x: -s * 0.5,  y: -s * 0.95))
    p.addCurve(to: CGPoint(x: 0, y: s * 0.38),
               control1: CGPoint(x: s * 0.5,   y: -s * 0.95),
               control2: CGPoint(x: s * 1.05,  y: -s * 0.15))
    p.closeSubpath()
    return p
}

private func starShape(outer ro: CGFloat, inner ri: CGFloat) -> Path {
    var p = Path()
    for i in 0..<10 {
        let r = i.isMultiple(of: 2) ? ro : ri
        let a = -.pi/2 + CGFloat(i) * .pi/5
        let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

// Equatable for BadgeType (needed for comparing)
extension BadgeType: Equatable {
    static func == (lhs: BadgeType, rhs: BadgeType) -> Bool {
        switch (lhs, rhs) {
        case (.dots, .dots): return true
        case (.bang, .bang): return true
        case (.question, .question): return true
        case (.dot, .dot): return true
        default: return false
        }
    }
}
