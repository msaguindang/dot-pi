import type { ExtensionAPI, ExtensionContext, WorkingIndicatorOptions } from "@earendil-works/pi-coding-agent";

const W = 18;
const MATRIX_CHARS = "ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘ012789Z";
const GLITCH_CHARS = "█▓▒░╳╱╲¥£€$#@!?&%~*";

const ACTION_QUOTES = [
	"Constructing additional pylons.",
	"Warping in agents.",
	"Routing carrier fleet.",
	"In the pipe, five by five.",
	"Engaging cloaking field.",
	"Vector locked in.",
	"Your agents are engaging the enemy.",
	"It shall be done.",
	"Consider it done.",
	"Power overwhelming.",
	"Agent fleet launched.",
	"Initiating.",
	"Commencing.",
	"Setting course.",
	"In transit HQ.",
	"Target designated.",
	"Locking in coordinates.",
	"Auto-turret engaged.",
	"Coordinating attack.",
	"Deploying...",
	"Deploy forces now.",
	"Engaging hostiles.",
	"Commencing bloodshed.",
	"Commencing bombardment.",
	"Annihilation commencing.",
	"Directing overload.",
	"Distortion field active.",
	"EMP deployed.",
	"Fire all missile clusters.",
	"Fire at will, commander.",
	"Glaive cannon armed.",
	"Initiating assault.",
	"Initiating purification.",
	"Locked on target.",
	"Moving into position.",
	"Moving out.",
	"Opening fire.",
	"Painting the target.",
	"Weapon systems engaged.",
	"Prismatic beams aligning.",
	"Pulling the trigger.",
	"Purging fire.",
	"Reinforcing psi-web.",
	"Suppressing fire.",
	"Switching to full auto.",
	"Targeting systems primed.",
	"Target acquired.",
	"Teleport successful.",
	"Thrusters to maximum.",
	"Turbines to full.",
	"Typhoon missiles locked.",
	"V-TOL, engaged.",
	"Warp field online.",
	"Weapons free.",
	"Weapons hot.",
	"Advancing on target.",
	"Covering ground.",
	"Kinetic matrix charged.",
	"Phase disruptors primed.",
	"Psi-web established.",
	"Pushing ahead.",
	"Ready to drop the hammer.",
	"Setting up shop.",
	"Strike now.",
	"Strike without warning.",
	"Taking aim.",
	"Taking flight.",
	"We advance.",
	"We move unseen.",
	"We strike as one.",
	"We strike from the skies.",
	"We face the enemy.",
	"Lock and load.",
	"Lock beams and incinerate.",
];

const THINKING_QUOTES = [
	"You must construct additional pylons.",
	"Harmonizing psionic matrix.",
	"Calibrating void energies.",
	"Spawn more agents.",
	"Securing telepresence.",
	"Initiating merge.",
	"Thoughts in chaos.",
	"Synthesizing essence.",
	"Spinning genetic sequences.",
	"Incubating strategies.",
	"Sensing psionic emanations.",
	"Receiving transmission.",
	"Scanning for targets.",
	"Decrypting data streams.",
	"Running system diagnostics.",
	"Running level one diagnostic.",
	"Establishing comm-link.",
	"Adjusting neural transmission",
	"Hailing frequencies open.",
	"Adjutant online.",
	"Comm-link online.",
	"Channel open.",
	"Systems functional.",
	"Transmit orders.",
	"Orders received.",
	"Coordinates received.",
	"I heed thy call.",
	"Acknowledged HQ.",
	"Nav-comm locked.",
	"Checklist protocol initiated.",
	"Awaiting orders.",
	"Awaiting confirmation.",
	"Awaiting evac.",
	"Awaiting your command.",
	"Awaiting directive.",
	"Standing by.",
	"Command authority registered.",
	"Data received, TACCOM.",
	"Downloading orders.",
	"Go ahead, TACCOM.",
	"Directive confirmed.",
	"Kill order received.",
	"Sensors are optimal.",
	"Test complete. All systems are working perfectly.",
	"Chronometrics steady.",
	"Extrapolating strings.",
	"Oracle perceiving.",
	"Dimensional strings attuned.",
	"How may I serve?",
	"I comprehend.",
	"I listen.",
	"Input command.",
	"Ten-four.",
	"Ten-two receiving.",
	"Radio check, over.",
	"Repeat last transmission.",
	"State your request.",
	"Status report.",
	"Protocols aligned.",
	"Enemy sighted.",
];

function rgb(r: number, g: number, b: number): string {
	return `\x1b[38;2;${r};${g};${b}m`;
}
const RESET = "\x1b[39m";

function randomNextIndex(current: number, length: number): number {
	if (length <= 1) return 0;
	let next = current;
	while (next === current) next = Math.floor(Math.random() * length);
	return next;
}

function generateMatrixFrames(count: number): string[] {
	const frames: string[] = [];
	for (let f = 0; f < count; f++) {
		let line = "";
		for (let i = 0; i < W; i++) {
			const char = MATRIX_CHARS[Math.floor(Math.random() * MATRIX_CHARS.length)]!;
			const intensity = (i - f + count * 2) % (W / 2);
			let color = rgb(0, 80, 0);
			if (intensity < 1) color = rgb(0, 255, 0);
			else if (intensity < 3) color = rgb(0, 160, 0);
			line += color + char;
		}
		frames.push(line + RESET);
	}
	return frames;
}

function generateGlitchFrames(count: number): string[] {
	// Muted Tokyo Night palette (Cyan, Purple, Blue, Yellow/Orange)
	const colors = [rgb(125, 207, 200), rgb(187, 154, 247), rgb(122, 162, 247), rgb(224, 175, 104)];
	const frames: string[] = [];
	for (let f = 0; f < count; f++) {
		let line = "";
		for (let i = 0; i < W; i++) {
			const color = colors[Math.floor(Math.random() * colors.length)]!;
			const char = GLITCH_CHARS[Math.floor(Math.random() * GLITCH_CHARS.length)]!;
			line += color + char;
		}
		frames.push(line + RESET);
	}
	return frames;
}

function generateTypewriterFrames(): string[] {
	return [
		rgb(150, 150, 150) + "..." + RESET,
		rgb(200, 200, 200) + "T.." + RESET,
		rgb(200, 200, 200) + "TR." + RESET,
		rgb(255, 255, 255) + "TRA" + RESET,
		rgb(200, 200, 200) + "RA." + RESET,
		rgb(150, 150, 150) + "A.." + RESET,
	];
}

const matrixFrames = generateMatrixFrames(30);
const glitchFrames = generateGlitchFrames(30);
const typewriterFrames = generateTypewriterFrames();

export default function (pi: ExtensionAPI): void {
	const matrixIndicator: WorkingIndicatorOptions = {
		frames: matrixFrames,
		intervalMs: 80,
	};
	
	const glitchIndicator: WorkingIndicatorOptions = {
		frames: glitchFrames,
		intervalMs: 60,
	};
	
	const typewriterIndicator: WorkingIndicatorOptions = {
		frames: typewriterFrames,
		intervalMs: 150,
	};

	let activeTools = 0;
	let isThinking = false;
	let subagentsBusy = false;
	let activeCtx: ExtensionContext | undefined;
	let messageInterval: ReturnType<typeof setInterval> | undefined;
	let showcaseInterval: ReturnType<typeof setInterval> | undefined;
	let showcaseStep = -1;
	let actionIndex = 0;
	let thinkingIndex = 0;

	let charIndex = 0;
	let currentFullMsg = "";
	let pauseTicks = 0;
	const PAUSE_DURATION_TICKS = 25; // 25 * 60ms = 1500ms

	function tickMessage(ctx: ExtensionContext): void {
		if (activeTools === 0 && !isThinking && !subagentsBusy) {
			if (messageInterval) {
				clearInterval(messageInterval);
				messageInterval = undefined;
			}
			ctx.ui.setWorkingMessage();
			return;
		}

		let frame = "";
		if (showcaseStep >= 0) {
			const activeIndicator = showcaseStep === 0 ? matrixIndicator : (showcaseStep === 1 ? glitchIndicator : typewriterIndicator);
			const fCount = activeIndicator.frames.length;
			if (fCount > 0) {
				frame = activeIndicator.frames[Math.floor(Date.now() / (activeIndicator.intervalMs || 80)) % fCount]! + " ";
			}
		}

		let quote = "";
		if (activeTools > 0 || subagentsBusy) {
			quote = ACTION_QUOTES[actionIndex % ACTION_QUOTES.length]!;
		} else {
			quote = THINKING_QUOTES[thinkingIndex % THINKING_QUOTES.length]!;
		}

		const targetFullMsg = quote;
		if (currentFullMsg !== targetFullMsg) {
			currentFullMsg = targetFullMsg;
			charIndex = 0;
			pauseTicks = 0;
		}

		if (charIndex < currentFullMsg.length) {
			charIndex++;
			const text = currentFullMsg.substring(0, charIndex);
			const cursor = charIndex % 2 === 0 ? "█" : "░";
			ctx.ui.setWorkingMessage(text + cursor);
			if (showcaseStep >= 0) {
				ctx.ui.setWidget("cyber-showcase", [frame + text + cursor], { placement: "belowEditor" });
			}
		} else {
			if (pauseTicks === 0) {
				ctx.ui.setWorkingMessage(currentFullMsg);
				if (showcaseStep >= 0) {
					ctx.ui.setWidget("cyber-showcase", [frame + currentFullMsg], { placement: "belowEditor" });
				}
			}
			pauseTicks++;
			if (pauseTicks >= PAUSE_DURATION_TICKS) {
				if (activeTools > 0 || subagentsBusy) actionIndex = randomNextIndex(actionIndex, ACTION_QUOTES.length);
				else thinkingIndex = randomNextIndex(thinkingIndex, THINKING_QUOTES.length);
			} else if (showcaseStep >= 0) {
				ctx.ui.setWidget("cyber-showcase", [frame + currentFullMsg], { placement: "belowEditor" });
			}
		}
	}

	function startMessageCycle(ctx: ExtensionContext): void {
		if (!messageInterval) {
			currentFullMsg = "";
			tickMessage(ctx);
			messageInterval = setInterval(() => tickMessage(ctx), 60);
		} else {
			currentFullMsg = ""; // Reset to start typing immediately on state change
		}
	}

	function stopMessageCycle(ctx: ExtensionContext): void {
		if (activeTools === 0 && !isThinking && !subagentsBusy) {
			if (messageInterval) {
				clearInterval(messageInterval);
				messageInterval = undefined;
			}
			ctx.ui.setWorkingMessage();
		}
	}

	pi.registerCommand("cyber", {
		description: "Test cyber-loader animations (matrix, glitch, typewriter, showcase, auto)",
		handler: async (args: string, ctx: ExtensionContext): Promise<void> => {
			const mode = args.trim().toLowerCase();
			if (showcaseInterval) {
				clearInterval(showcaseInterval);
				showcaseInterval = undefined;
				showcaseStep = -1;
				ctx.ui.setWidget("cyber-showcase", undefined);
			}
			if (mode === "matrix") {
				isThinking = true;
				activeTools = 0;
				ctx.ui.setWorkingVisible(true);
				ctx.ui.setWorkingIndicator(matrixIndicator);
				startMessageCycle(ctx);
				ctx.ui.notify("Cyber-loader overridden: Matrix", "info");
			} else if (mode === "glitch") {
				isThinking = false;
				activeTools = 1;
				ctx.ui.setWorkingVisible(true);
				ctx.ui.setWorkingIndicator(glitchIndicator);
				startMessageCycle(ctx);
				ctx.ui.notify("Cyber-loader overridden: Glitch", "info");
			} else if (mode === "typewriter") {
				isThinking = false;
				activeTools = 0;
				stopMessageCycle(ctx);
				ctx.ui.setWorkingVisible(true);
				ctx.ui.setWorkingIndicator(typewriterIndicator);
				ctx.ui.setWorkingMessage("Transmitting fallback test");
				ctx.ui.notify("Cyber-loader overridden: Typewriter (fallback)", "info");
			} else if (mode === "showcase") {
				ctx.ui.notify("Starting Cyber-loader showcase...", "info");
				let step = 0;
				
				const runShowcaseStep = () => {
					showcaseStep = step;
					if (step === 0) {
						isThinking = true;
						activeTools = 0;
						startMessageCycle(ctx);
						ctx.ui.notify("Showcase [1/3]: Matrix Rain", "info");
					} else if (step === 1) {
						isThinking = false;
						activeTools = 1;
						startMessageCycle(ctx);
						ctx.ui.notify("Showcase [2/3]: Glitch", "info");
					} else if (step === 2) {
						isThinking = false;
						activeTools = 0;
						stopMessageCycle(ctx);
						// Manually drive the widget for step 2 since startMessageCycle is stopped
						let tIndex = 0;
						const typewriterInterval = setInterval(() => {
							if (showcaseStep !== 2) {
								clearInterval(typewriterInterval);
								return;
							}
							const frame = typewriterIndicator.frames[Math.floor(Date.now() / typewriterIndicator.intervalMs) % typewriterIndicator.frames.length];
							ctx.ui.setWidget("cyber-showcase", [frame + " Transmitting fallback test"], { placement: "belowEditor" });
						}, 60);
						ctx.ui.notify("Showcase [3/3]: Typewriter", "info");
					} else {
						if (showcaseInterval) {
							clearInterval(showcaseInterval);
							showcaseInterval = undefined;
							showcaseStep = -1;
							ctx.ui.setWidget("cyber-showcase", undefined);
						}
						isThinking = false;
						activeTools = 0;
						stopMessageCycle(ctx);
						ctx.ui.notify("Showcase complete. Restored to Auto mode.", "info");
					}
					step++;
				};
				
				runShowcaseStep(); // step 0 executes immediately
				showcaseInterval = setInterval(runShowcaseStep, 4500);
			} else if (mode === "auto" || mode === "reset") {
				isThinking = false;
				activeTools = 0;
				stopMessageCycle(ctx);
				ctx.ui.setWorkingIndicator(matrixIndicator);
				ctx.ui.setWorkingVisible(false);
				ctx.ui.notify("Cyber-loader restored to Auto mode", "info");
			} else {
				ctx.ui.notify("Usage: /cyber [matrix|glitch|typewriter|showcase|auto]", "error");
			}
		},
	});

	pi.on("session_start", (_event: any, ctx: ExtensionContext): void => {
		activeCtx = ctx;
		activeTools = 0;
		isThinking = false;
		ctx.ui.setWorkingIndicator(matrixIndicator);
		if (messageInterval) {
			clearInterval(messageInterval);
			messageInterval = undefined;
		}
		ctx.ui.setWorkingMessage(); // reset to default
	});

	pi.on("agent_start", (_event: any, ctx: ExtensionContext): void => {
		activeCtx = ctx;
		isThinking = true;
		if (activeTools === 0 && !subagentsBusy) {
			ctx.ui.setWorkingIndicator(matrixIndicator);
		}
		startMessageCycle(ctx);
	});

	pi.on("agent_end", (_event: any, ctx: ExtensionContext): void => {
		activeCtx = ctx;
		isThinking = false;
		stopMessageCycle(ctx);
	});

	pi.on("tool_execution_start", (_event: any, ctx: ExtensionContext): void => {
		activeCtx = ctx;
		activeTools++;
		ctx.ui.setWorkingIndicator(glitchIndicator);
		startMessageCycle(ctx);
	});

	pi.on("tool_execution_end", (_event: any, ctx: ExtensionContext): void => {
		activeCtx = ctx;
		activeTools--;
		if (activeTools <= 0 && !subagentsBusy) {
			activeTools = 0;
			ctx.ui.setWorkingIndicator(matrixIndicator);
			startMessageCycle(ctx);
			stopMessageCycle(ctx);
		}
	});

	// Listen for pi-subagents emitting "herdr:busy" on the internal pi.events bus
	(pi as any).events?.on("herdr:busy", (payload: any) => {
		if (payload && typeof payload.active === "boolean") {
			subagentsBusy = payload.active;
			if (activeCtx) {
				if (subagentsBusy) {
					activeCtx.ui.setWorkingVisible(true);
					activeCtx.ui.setWorkingIndicator(glitchIndicator);
					startMessageCycle(activeCtx);
				} else {
					if (activeTools <= 0) {
						activeCtx.ui.setWorkingIndicator(matrixIndicator);
						if (!isThinking) {
							stopMessageCycle(activeCtx);
							activeCtx.ui.setWorkingVisible(false);
						} else {
							startMessageCycle(activeCtx);
						}
					}
				}
			}
		}
	});

	pi.on("session_shutdown", (_event: any, _ctx: ExtensionContext): void => {
		if (messageInterval) {
			clearInterval(messageInterval);
			messageInterval = undefined;
		}
		if (showcaseInterval) {
			clearInterval(showcaseInterval);
			showcaseInterval = undefined;
			showcaseStep = -1;
		}
	});
}
