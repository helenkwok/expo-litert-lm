import type { LiteRtLoadResult, LiteRtPreferredBackend, LiteRtTokenEvent } from './index';
type Listener = (event: LiteRtTokenEvent) => void;
declare class ExpoLitertLmWebModule {
    private litertLm;
    private engine;
    private conversation;
    private loadConfig;
    private activeGenerationId;
    private listeners;
    isAvailableAsync(): Promise<boolean>;
    sampleMemoryAsync(): Promise<number>;
    loadModelAsync(modelPath: string, maxTokens: number, topK: number, temperature: number, preferredBackend?: LiteRtPreferredBackend): Promise<LiteRtLoadResult>;
    generateResponseAsync(prompt: string): Promise<string>;
    generateAudioResponseAsync(_audioPath: string, _prompt: string): Promise<string>;
    cancelGenerateResponseAsync(): Promise<void>;
    unloadModelAsync(): Promise<void>;
    addListener(_eventName: string, listener: Listener): {
        remove: () => void;
    };
    private emit;
    private unloadInternal;
    private requireLitertLm;
}
declare const expoLitertLmWebModule: ExpoLitertLmWebModule;
export default expoLitertLmWebModule;
//# sourceMappingURL=ExpoLitertLmModule.web.d.ts.map