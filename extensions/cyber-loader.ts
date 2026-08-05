import type { ExtensionAPI, ExtensionContext, WorkingIndicatorOptions } from "@earendil-works/pi-coding-agent";

const W = 18;
const MATRIX_CHARS = "ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘ012789Z";
const GLITCH_CHARS = "█▓▒░╳╱╲¥£€$#@!?&%~*";

const ACTION_QUOTES = [
	"Right away, sir.",
	"Acknowledged.",
	"I'm on it.",
	"Orders received.",
	"Initiating.",
	"As you will.",
	"Commencing.",
	"Vector locked in.",
	"Coordinates received.",
	"Course set.",
	"Engaging.",
	"Heading set.",
	"Telepresence secure.",
	"It shall be done.",
	"I read ya."
];

const THINKING_QUOTES = [
	"Thoughts in chaos.",
	"State thy bidding.",
	"Power overwhelming.",
	"I stand ready.",
	"Receiving.",
	"Awaiting command.",
	"Telepresence secure."
];

function rgb(r: number, g: number, b: number): string {
	return `\x1b[38;2;${r};${g};${b}m`;
}
const RESET = "\x1b[39m";

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
		rgb(200, 200, 200) + "TY." + RESET,
		rgb(255, 255, 255) + "TYP" + RESET,
		rgb(200, 200, 200) + "YP." + RESET,
		rgb(150, 150, 150) + "P.." + RESET,
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
	let messageInterval: ReturnType<typeof setInterval> | undefined;
	let showcaseInterval: ReturnType<typeof setInterval> | undefined;
	let actionIndex = 0;
	let thinkingIndex = 0;

	let charIndex = 0;
	let currentFullMsg = "";
	let pauseTicks = 0;
	const PAUSE_DURATION_TICKS = 25; // 25 * 60ms = 1500ms

	function tickMessage(ctx: ExtensionContext): void {
		if (activeTools === 0 && !isThinking) {
			if (messageInterval) {
				clearInterval(messageInterval);
				messageInterval = undefined;
			}
			ctx.ui.setWorkingMessage();
			return;
		}

		let prefix = "";
		let quote = "";
		if (activeTools > 0) {
			prefix = "Working: ";
			quote = ACTION_QUOTES[actionIndex % ACTION_QUOTES.length]!;
		} else {
			prefix = "Thinking: ";
			quote = THINKING_QUOTES[thinkingIndex % THINKING_QUOTES.length]!;
		}

		const targetFullMsg = prefix + quote;
		if (currentFullMsg !== targetFullMsg) {
			currentFullMsg = targetFullMsg;
			charIndex = prefix.length;
			pauseTicks = 0;
		}

		if (charIndex < currentFullMsg.length) {
			charIndex++;
			const text = currentFullMsg.substring(0, charIndex);
			const cursor = charIndex % 2 === 0 ? "█" : "░";
			ctx.ui.setWorkingMessage(text + cursor);
		} else {
			if (pauseTicks === 0) {
				ctx.ui.setWorkingMessage(currentFullMsg);
			}
			pauseTicks++;
			if (pauseTicks >= PAUSE_DURATION_TICKS) {
				if (activeTools > 0) actionIndex++;
				else thinkingIndex++;
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
		if (activeTools === 0 && !isThinking) {
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
			}
			if (mode === "matrix") {
				ctx.ui.setWorkingVisible(true);
				ctx.ui.setWorkingIndicator(matrixIndicator);
				ctx.ui.notify("Cyber-loader overridden: Matrix (Working/Idle)", "info");
			} else if (mode === "glitch") {
				ctx.ui.setWorkingVisible(true);
				ctx.ui.setWorkingIndicator(glitchIndicator);
				ctx.ui.notify("Cyber-loader overridden: Glitch (Tool Execution)", "info");
			} else if (mode === "typewriter") {
				ctx.ui.setWorkingVisible(true);
				ctx.ui.setWorkingIndicator(typewriterIndicator);
				ctx.ui.notify("Cyber-loader overridden: Typewriter (Thinking)", "info");
			} else if (mode === "showcase") {
				ctx.ui.setWorkingVisible(true);
				ctx.ui.notify("Starting Cyber-loader showcase...", "info");
				let step = 0;
				
				const runShowcaseStep = () => {
					if (step === 0) {
						ctx.ui.setWorkingIndicator(matrixIndicator);
						ctx.ui.notify("Showcase [1/3]: Matrix Rain (Idle)", "info");
					} else if (step === 1) {
						ctx.ui.setWorkingIndicator(glitchIndicator);
						ctx.ui.notify("Showcase [2/3]: Glitch (Working)", "info");
					} else if (step === 2) {
						ctx.ui.setWorkingIndicator(typewriterIndicator);
						ctx.ui.notify("Showcase [3/3]: Typewriter", "info");
					} else {
						if (showcaseInterval) {
							clearInterval(showcaseInterval);
							showcaseInterval = undefined;
						}
						ctx.ui.setWorkingIndicator(matrixIndicator);
						ctx.ui.setWorkingVisible(false);
						ctx.ui.notify("Showcase complete. Restored to Auto mode.", "info");
					}
					step++;
				};
				
				runShowcaseStep(); // step 0 executes immediately
				showcaseInterval = setInterval(runShowcaseStep, 3000);
			} else if (mode === "auto" || mode === "reset") {
				activeTools = 0;
				ctx.ui.setWorkingIndicator(matrixIndicator);
				ctx.ui.setWorkingVisible(false);
				ctx.ui.notify("Cyber-loader restored to Auto mode", "info");
			} else {
				ctx.ui.notify("Usage: /cyber [matrix|glitch|typewriter|showcase|auto]", "error");
			}
		},
	});

	pi.on("session_start", (_event: any, ctx: ExtensionContext): void => {
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
		isThinking = true;
		if (activeTools === 0) {
			ctx.ui.setWorkingIndicator(matrixIndicator);
		}
		startMessageCycle(ctx);
	});

	pi.on("agent_end", (_event: any, ctx: ExtensionContext): void => {
		isThinking = false;
		stopMessageCycle(ctx);
	});

	pi.on("tool_execution_start", (_event: any, ctx: ExtensionContext): void => {
		activeTools++;
		ctx.ui.setWorkingIndicator(glitchIndicator);
		startMessageCycle(ctx);
	});

	pi.on("tool_execution_end", (_event: any, ctx: ExtensionContext): void => {
		activeTools--;
		if (activeTools <= 0) {
			activeTools = 0;
			ctx.ui.setWorkingIndicator(matrixIndicator);
			startMessageCycle(ctx);
			stopMessageCycle(ctx);
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
		}
	});
}
