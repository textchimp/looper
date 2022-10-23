<template>
  <div class="slider">
    <div ref="outer"   class="outer" :style="$attrs.style"
      @click="update" 
      @mousedown="down"
      @mouseup="up"
      @mousemove="move"
      @wheel="wheel"
      @dblclick="dblclick"
      @mouseleave="mouseleave"
      @auxclick="dblclick"
    >
      <div ref="inner" class="inner" :style="getStyle"></div>
    </div>
    <div class="label" @click="dblclick">
      {{ label }}: <strong>{{ valueFormatted }}</strong>
    </div>
  </div>
</template>

<script>
export default {
  props: ['modelValue', 'min', 'max', 'defaultValue', 'label'],
  data(){
    return {
      dragging: false,
      lastDragX: 0,
      percent: this.initialPercent || 0.5,
      // default: this.defaultValue,
      currentValue: this.defaultValue,
      width: this.initialWidth || 200,
    };
  },
  watch: {
    percent(v){
      this.currentValue = this.min + ((this.max - this.min) * this.percent);
      this.$emit('update:modelValue', this.currentValue);
    },
    modelValue(v){
      console.log('modelValue', v);
      this.percent = this.valueNorm(v);
    }
  },
  computed: {
    getStyle(){
      return { width: Math.min(this.percent * 100, 100) + '%' };
    },

    valueFormatted(){
      const v = this.currentValue;
      return v % 1.0 > 0.0 ? v.toFixed(2) : Math.floor(v);
    }

  },
  methods: {
    update(ev){
      console.log('got it', ev.layerX);
      // console.log('width', this.$refs.outer.offsetWidth);
      this.percent = ev.layerX / this.$refs.outer.offsetWidth;
    },

    valueNorm(v){
      return ((v - this.min) / (this.max - this.min)); //* this.$refs.outer.offsetWidth;
    },


    down(ev){
      this.dragging = true;
      this.$emit('down', ev);
    },

    up(ev){
      this.dragging = false;
      this.$emit('up', ev);
    },

    move(ev){
      this.$emit('move', this.dragging, ev);
      if( this.dragging){
        // console.log('move', v);
        this.lastDragX = ev.layerX;
        this.percent = ev.layerX / this.$refs.outer.offsetWidth;
      }
    },

    wheel(ev){
      const delta = ev.deltaY / 400.0;
      this.percent =  Math.max(0, Math.min(1.0, this.percent - delta) );
      this.$emit('wheel', ev);
    },

    dblclick(ev){
      ev.preventDefault();
      console.log('dblclick', ev);
      if(this.defaultValue && this.min && this.max){
        this.percent = this.valueNorm(this.defaultValue);
        // this.currentValue = this.defaultValue; // need this?
        this.$emit('update:modelValue', this.defaultValue);
      }
      this.$emit('dblclick', ev);
    },

    mouseleave(ev){
      console.log('mouseleave', ev);
      this.$emit('mouseleave', ev);
      if( this.dragging){
        this.percent =  this.lastDragX / this.$refs.outer.offsetWidth;
        this.dragging = false;
      }
    },

  },
}
</script>

<style>
.outer {
  position: relative;
  border: 1px solid black;
  transition: 0.2;
  box-sizing: border-box;
  margin: 0 auto;
  width: 200px;
  /* height: 50px; */
  height: 30% !important;
  transition: 0.1s;
}

.slider:hover > .outer {
  border: 1px solid grey;
  height: 100% !important;
}
.slider:hover .label{
  opacity: 1.0;
}



.inner {
  position: absolute; 
  left: 0;
  display: inline-block;
  /* height: 30%; */
  height: 100%;
  width: 200px;
  background-color: #ff00007f;
}

.label {
  font-size: 12pt;
  color: grey;
  opacity: 0.4;
  transition: 0.2s;
  cursor: pointer;
}
</style>