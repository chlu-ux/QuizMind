<script setup lang="ts">
import { computed } from 'vue'
import DOMPurify from 'dompurify'
import { Marked } from 'marked'
import { fenceSvg, isPlainSvg, svgDataUri, withMediaUrls } from '@/utils/media'

const props = defineProps<{ source: string }>()

// Uploaded files and model replies are not trusted markup: sanitize before v-html.
// A ```svg block in an AI answer is a diagram: shown as an image, which cannot run scripts.
const marked = new Marked({
  async: false,
  gfm: true,
  breaks: false,
  renderer: {
    code({ text, lang }) {
      return lang === 'svg' && isPlainSvg(text) ? `<img class="svgfig" alt="示意图" src="${svgDataUri(text)}">` : false
    },
  },
})

const html = computed(() => DOMPurify.sanitize(marked.parse(fenceSvg(withMediaUrls(props.source))) as string))
</script>

<template>
  <div class="md" v-html="html" />
</template>

<style scoped>
.md { line-height: 1.75; word-break: break-word; }
.md :deep(:first-child) { margin-top: 0; }
.md :deep(:last-child) { margin-bottom: 0; }
.md :deep(h1), .md :deep(h2), .md :deep(h3), .md :deep(h4) { margin: 1.4em 0 0.5em; line-height: 1.35; }
.md :deep(h1) { font-size: 1.6em; padding-bottom: 0.3em; border-bottom: 1px solid var(--el-border-color-lighter); }
.md :deep(h2) { font-size: 1.35em; padding-bottom: 0.25em; border-bottom: 1px solid var(--el-border-color-lighter); }
.md :deep(h3) { font-size: 1.15em; }
.md :deep(p) { margin: 0.6em 0; }
.md :deep(ul), .md :deep(ol) { padding-left: 1.6em; }
.md :deep(code) { padding: 1px 5px; border-radius: 4px; background: var(--el-fill-color); font: 0.9em ui-monospace, Menlo, monospace; }
.md :deep(pre) { padding: 12px 14px; border-radius: 8px; background: var(--el-fill-color); overflow-x: auto; }
.md :deep(pre code) { padding: 0; background: none; }
.md :deep(blockquote) { margin: 0.8em 0; padding: 0 1em; color: var(--el-text-color-secondary); border-left: 4px solid var(--el-border-color); }
.md :deep(table) { border-collapse: collapse; display: block; overflow-x: auto; }
.md :deep(th), .md :deep(td) { padding: 6px 12px; border: 1px solid var(--el-border-color); }
.md :deep(img) { max-width: 100%; background: #fff; }
.md :deep(img.svgfig) { padding: 8px; border: 1px solid var(--el-border-color); border-radius: 6px; }
.md :deep(hr) { border: 0; border-top: 1px solid var(--el-border-color); }
</style>
