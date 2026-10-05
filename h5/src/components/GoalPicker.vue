<script setup lang="ts">
import { computed, ref } from 'vue'

const props = defineProps<{
  label: string
  unit: string
  /** The value the box is switched on to when "custom" is chosen without one, and its largest value. */
  presets: number[]
  max: number
  modelValue: number | null
}>()
const emit = defineEmits<{ 'update:modelValue': [value: number | null] }>()

// "自定义" stays selected while the box is being edited, even if what is typed momentarily matches a preset.
const custom = ref(props.modelValue !== null && !props.presets.includes(props.modelValue))
const isCustom = computed(() => custom.value)

function pick(v: number | null) {
  custom.value = false
  emit('update:modelValue', v)
}
function startCustom() {
  custom.value = true
  if (props.modelValue === null) emit('update:modelValue', props.presets[0])
}
function typed(e: Event) {
  const n = Number.parseInt((e.target as HTMLInputElement).value, 10)
  emit('update:modelValue', Number.isFinite(n) && n >= 1 ? Math.min(n, props.max) : null)
}
</script>

<template>
  <div class="goal-picker" role="group" :aria-label="label">
    <div class="muted small">{{ label }}</div>
    <div class="chips">
      <button class="pick" :class="{ on: modelValue === null && !isCustom }" @click="pick(null)">关闭</button>
      <button
        v-for="p in presets"
        :key="p"
        class="pick"
        :class="{ on: !isCustom && modelValue === p }"
        @click="pick(p)"
      >
        {{ p }}
      </button>
      <button class="pick" :class="{ on: isCustom }" @click="startCustom">自定义</button>
    </div>
    <label v-if="isCustom" class="row gap">
      <input class="input goal-input" type="number" inputmode="numeric" min="1" :max="max" :value="modelValue ?? ''" :aria-label="`${label}（自定义）`" @input="typed" />
      <span>{{ unit }}</span>
    </label>
  </div>
</template>
