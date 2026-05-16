/*
 * Phase 14 Stage B spike harness — exercises the full Expo + RN + native
 * ExpoLitertLm bridge against the SAME gemma3-1b-it-int4.litertlm + SAME
 * 256-token prefill prompt used in Stage A (14-06). The Stage-A↔Stage-B
 * delta on max(phys_footprint) isolates the JS + RN bridge overhead.
 *
 * Bundle id: com.helenkwok.expolitertlmexample (mirrors app.json).
 */
import * as DocumentPicker from 'expo-document-picker';
// Legacy file-system API (documentDirectory / writeAsStringAsync) lives behind
// the /legacy subpath as of SDK 55's next-gen API rewrite. We use legacy here
// because the Stage A NDJSON schema mirrors a simple text-blob write — the new
// File/Paths class API would add ceremony with no behavioural benefit for a
// throwaway spike harness.
import * as FileSystem from 'expo-file-system/legacy';
import React, { useEffect, useRef, useState } from 'react';
import { Button, ScrollView, StyleSheet, Text, View } from 'react-native';

import {
  addLiteRtTokenListener,
  cancelLiteRtGeneration,
  generateLiteRtResponse,
  loadLiteRtModel,
  sampleMemoryAsync,
  type LiteRtTokenEvent,
} from 'expo-litert-lm';

// 256-token prefill — verbatim copy of SpikeRunner.swift `prefillPrompt`
// (Stage A constant). Holding this fixed keeps the A↔B comparison apples-to-
// apples; per the plan, "copy the prompt-string constant verbatim from
// SpikeRunner.swift" (Phase 14 14-07 PLAN Task 4 step 4e).
//
// Calls loadModelAsync / generateResponseAsync / cancelGenerateResponseAsync
// via the named JS wrappers above (loadLiteRtModel / generateLiteRtResponse /
// cancelLiteRtGeneration map 1:1 to those native AsyncFunctions).
const PREFILL_PROMPT: string = (() => {
  const seed =
    'Summarize the following safety advice in two sentences: ' +
    'stay calm, find shelter, call emergency services if safe, follow local ' +
    'instructions, and check on neighbors when conditions allow. ';
  let s = '';
  while (s.length < 1024) s += seed;
  return s.slice(0, 1024);
})();

const SAMPLE_INTERVAL_MS = 250;
const MAX_TOKENS = 320; // 256 prefill + 64 decode margin, matches Stage A D-04
const TOP_K = 40;
const TEMPERATURE = 0.7;

type Sample = { ts_ms: number; phys_footprint_mb: number };

export default function App() {
  const [modelPath, setModelPath] = useState<string | null>(null);
  const [output, setOutput] = useState<string>('');
  const [running, setRunning] = useState<boolean>(false);
  const [peakMb, setPeakMb] = useState<number>(0);
  const [currentMb, setCurrentMb] = useState<number>(0);
  const [cancelLatencyMs, setCancelLatencyMs] = useState<number | null>(null);
  const [errorText, setErrorText] = useState<string | null>(null);

  const samplesRef = useRef<Sample[]>([]);
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const cancelTsRef = useRef<number | null>(null);

  const finishCancelLatency = () => {
    if (cancelTsRef.current === null) return;
    setCancelLatencyMs(Date.now() - cancelTsRef.current);
    cancelTsRef.current = null;
  };

  useEffect(() => {
    const sub = addLiteRtTokenListener((event: LiteRtTokenEvent) => {
      setOutput(event.text);
      if (cancelTsRef.current !== null && event.done) {
        finishCancelLatency();
      }
    });
    return () => sub.remove();
  }, []);

  const pickModel = async () => {
    setErrorText(null);
    const res = await DocumentPicker.getDocumentAsync({
      copyToCacheDirectory: false,
      multiple: false,
    });
    if (res.canceled) return;
    const uri = res.assets?.[0]?.uri;
    if (uri) {
      // Keep the picker URI intact so the native module exercises its
      // file:// URL normalization path.
      setModelPath(uri);
    }
  };

  const startPolling = () => {
    samplesRef.current = [];
    setPeakMb(0);
    setCurrentMb(0);
    pollRef.current = setInterval(async () => {
      const mb = await sampleMemoryAsync();
      const ts = Date.now();
      samplesRef.current.push({ ts_ms: ts, phys_footprint_mb: mb });
      setCurrentMb(mb);
      setPeakMb((prev) => (mb > prev ? mb : prev));
    }, SAMPLE_INTERVAL_MS);
  };

  const stopPollingAndWrite = async () => {
    if (pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }
    try {
      const ndjson = samplesRef.current
        .map((s) => JSON.stringify(s))
        .join('\n');
      const dir = FileSystem.documentDirectory ?? '';
      const path = `${dir}rss-stageB-${Date.now()}.ndjson`;
      await FileSystem.writeAsStringAsync(path, ndjson);
    } catch (e) {
      // Non-fatal: NDJSON write failure shouldn't mask the on-screen peakMb.
      console.warn('[StageB] NDJSON write failed:', e);
    }
  };

  const runSpike = async () => {
    if (!modelPath || running) return;
    setRunning(true);
    setOutput('');
    setErrorText(null);
    setCancelLatencyMs(null);
    cancelTsRef.current = null;
    startPolling();
    try {
      await loadLiteRtModel(modelPath, {
        maxTokens: MAX_TOKENS,
        topK: TOP_K,
        temperature: TEMPERATURE,
      });
      await generateLiteRtResponse(PREFILL_PROMPT);
    } catch (e) {
      setErrorText(e instanceof Error ? e.message : String(e));
    } finally {
      finishCancelLatency();
      await stopPollingAndWrite();
      setRunning(false);
    }
  };

  const cancel = async () => {
    if (!running) return;
    cancelTsRef.current = Date.now();
    await cancelLiteRtGeneration();
  };

  return (
    <View style={styles.root}>
      <Text style={styles.title}>Stage B — Expo bridge spike</Text>
      <Text style={styles.subtitle}>
        Phase 14 / 14-07 — same model + prompt as Stage A
      </Text>

      <View style={styles.row}>
        <Button title="Pick .litertlm model" onPress={pickModel} />
      </View>
      <Text style={styles.path} numberOfLines={1}>
        {modelPath ?? '(no model picked)'}
      </Text>

      <View style={styles.row}>
        <Button
          title={running ? 'Running…' : 'Run spike'}
          onPress={runSpike}
          disabled={!modelPath || running}
        />
        {running && <Button title="Cancel" color="#cc0000" onPress={cancel} />}
      </View>

      <View style={styles.metrics}>
        <Text style={styles.peak}>peak {peakMb.toFixed(1)} MB</Text>
        <Text style={styles.current}>now {currentMb.toFixed(1)} MB</Text>
        {cancelLatencyMs !== null && (
          <Text style={styles.cancel}>
            Cancel latency: {cancelLatencyMs} ms
          </Text>
        )}
      </View>

      <ScrollView style={styles.outputBox}>
        <Text style={styles.outputText}>{output}</Text>
      </ScrollView>

      {errorText && <Text style={styles.error}>{errorText}</Text>}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, padding: 16, paddingTop: 60, backgroundColor: '#fff' },
  title: { fontSize: 22, fontWeight: '700' },
  subtitle: { fontSize: 13, color: '#666', marginBottom: 16 },
  row: { flexDirection: 'row', gap: 12, marginVertical: 8 },
  path: { fontSize: 11, color: '#888', marginBottom: 8 },
  metrics: { marginVertical: 12 },
  peak: { fontSize: 36, fontWeight: '700', color: '#003366' },
  current: { fontSize: 14, color: '#444' },
  cancel: { fontSize: 14, color: '#cc0000', marginTop: 4 },
  outputBox: {
    flex: 1,
    backgroundColor: '#f5f5f5',
    padding: 12,
    borderRadius: 8,
    marginTop: 8,
  },
  outputText: { fontSize: 13, fontFamily: 'Menlo' },
  error: { color: '#cc0000', marginTop: 8 },
});
