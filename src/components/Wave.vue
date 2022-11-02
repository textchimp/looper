<template>
  <div>
    <!-- action: {{ waveStore.status }} -->
      <!-- @wheel="handleScrollZoom"  -->
    <div id="waveform" ref="waveform" 
      @click="handleWaveClick"
      @auxclick="handleMiddleClick"
      :class="isRecording && 'recording'"
    />
  </div>
</template>

<script>
/*
  TODO:

  - 'pause' ws event triggering every region loop iteration, WHY? (Not for initial default looping of whole wave, though)

  - doubled up on `keysHeld` handler and data

  - ZoomToMouse package works, but still zooms to cursor during playback - how to prevent?
    - wavesurfer.params.autoCenter = false;   but then never follows playing cursor... how to re-center once?

*/

const MIN_ZOOM_LEVEL = 160;
const MAX_ZOOM_LEVEL = 500;
const WAVE_HEIGHT_FACTOR = 0.85;

const REGION_RESIZE_SMALL = 0.01;
const REGION_RESIZE_MEDIUM = 0.1;
const REGION_RESIZE_LARGE = 0.2;


let chunks = [];

const env = process.env.NODE_ENV;


import WaveSurfer from 'wavesurfer.js';
import RegionsPlugin from 'wavesurfer.js/dist/plugin/wavesurfer.regions.min.js';
import ZoomToMousePlugin from "wavesurfer-zoom-to-mouse-plugin";

// import {useWavePlayerStore} from '@/stores/wavePlayer.js';


let wavesurfer = null;
const filters = {};


export default {
  name: 'Wave',
  // components: { Slider },
  props: [ 'inputDeviceId', 'channelCount' ],
  data(){
    return {
      // STATE
      playbackRate: 1.0,
      zoomLevel: MIN_ZOOM_LEVEL,
      regionIsLooping: false,
      isRecording: false,
      isWaitingToRecord: false,
      monitorOnStart: true,
      recordThreshold: 0.1,
      hasEverRecorded: false,
      recordClass: '',
      lastRegion: null,
      regionCount: 0,
      
      // waveStore: useWavePlayerStore(),

      // audioDevices: {},
      // prevAudioDevices: {}, // for keeping track of added device
      // selectedInputDeviceName: null,
      // selectedInputDevice: null,
      selectedOutputDevice: {},
      inputIsMono: false,

      keysHeld: {
        Control: false,
        Alt: false,
        Meta: false,
        Shift: false,
      },

      // props?
      lowpassFilterFreq: 0,
      stereoPan: 0, 
    };
  },

  mounted(){
    this.initWavesurfer();
    this.initFileDragDrop();
    this.initKeyHandlers();

    // console.log('STORE', this.waveStore.status);

    // Handler to load pasted URL
    document.addEventListener('paste', (e) => {
      const clipboardData = e.clipboardData || window.clipboardData;
      const pastedData = clipboardData.getData('Text');
      console.log('PASTE', pastedData);
      if(pastedData.startsWith('http')){
        wavesurfer.load( pastedData );
        // this.hasEverRecorded = true; // prevent spacebar from recording
      }
    });

  }, // mounted()


  beforeDestroy() {
    // this.bus.$off("eventName", this.eventHandler);
  },


  computed: {

    recordingStatus(){
      return this.isRecording ? 'Recording...' : '';
    },

    selectedInputDeviceName(){
      return this.audioDevices[this.selectedInputDevice] || '(none)';
    },

    selectedInputDeviceNameAbbrev(){
      const name = this.audioDevices[this.selectedInputDevice];
      if(!name) return '(none)';
      const abbrev = name.split(' ').slice(0, 2).map(s => s.substring(0, 3)).join('');
      const mono = this.inputIsMono ? ' (mono)' : '';
      return abbrev + mono;
    },

    getMicMonitorStyle(){
      // can't just use 'v-if' because mic plugin needs to find container element or throws
      return this.isRecording ? 'display: inline-block' : 'display: none' ;
    },

    getWaveformStyle(){
      return this.isRecording ? 'display: none' : 'display: inline-block' ;
    },

  },


  watch: {

    load(v){
      console.log('watch LOAD:', v);
      wavesurfer.load(v);
    },

    action(v){

    },

    state(v){
      console.log('WAVE STATE:', v);
      switch(v){
      case 'cleared':
        wavesurfer.stop();
        wavesurfer.empty();
        wavesurfer.clearRegions();
        break;
          
      case 'playPause':
        wavesurfer.playPause();
        break;

      default:
        console.log('******* unhandled state!');
      }
    },

    channelCount(v){
      console.log('channelCount prop changed:', v);
      wavesurfer.params.splitChannels = (v == 2);      
    },

    // Don't actually think this is necessary (since we never tell it the
    // device to use directly anyway)... only for recorder
    // Maybe when setSinkId for output is changed?
    // inputDeviceId(v){
    //   console.log('WATCH inputDeviceId', 'initWavesurfer()');
    //   this.initWavesurfer();
    // },
    
    playbackRate(v){
      if( v > 0.13 && v < 2.7 ){
        wavesurfer.setPlaybackRate(Number(v));
      } 
    },

    lowpassFilterFreq(v){
      console.log('lowpass', v);
      // l.frequency.value = v;
      g.gain.value = v;
    },

    stereoPan(v){
      filters.panner.pan.value = v;
      d(v);
    },

    // NO! Watchers are async, which is too hard to debug
    // So instead: manually run this.initRecorder() after change to input
    // selectedInputDevice(v){
    //   console.log('%cWATCHER: selectedInputDevice', 'color: blue');
    //   this.initRecorder(); // re-initialise audio input
    // },

  }, // watch



  methods: {


    initWavesurfer(){
       console.log('%cinitWavesurfer():', 'color: red; font-size: 1.2rem');


      wavesurfer = WaveSurfer.create({
        container: this.$refs.waveform,
        waveColor: '#A8DBA8',
        progressColor: '#3B8686',

        forceDecode: true, // test! better zoom perf?
        pixelRatio: 1,

        splitChannels: true, // could be changed by this.inputIsMono

        fillParent: true,
        scrollParent: false,
        hideScrollbar: false,
        // minPxPerSec: 50,
        // pixelRatio: 1,
        
        // autoCenter: false,

        responsive: true,

        // ISSUE: with WebAudio, 'setPlaybackRate'  actually changes rate (inc. pitch)
        // instead of a nice time stretch...
        backend: 'WebAudio',  // wavesurfer.backend  ??? MediaElement / WebAudio
        plugins: [
          RegionsPlugin.create({
              dragSelection: {
                  slop: 5 // 5
              }
          }),  // RegionsPlugin.create()

          // TODO: works, but still zooms to cursor during playback - how to prevent?
          ZoomToMousePlugin.create({
            maxPxPerSec: 5000 // default 1000
          }),
        ]
      });


      // w.setCursorColor('rgb(0,0,0,0.0)'); // to hide 

      wavesurfer.on('error', function(e) {
          console.error(e);
      });

      wavesurfer.on('waveform-ready', e => {
        // This event is needed when using the MediaElement backend, to wait until 
        // the buffer is defined
        const height = window.innerHeight / wavesurfer.backend.buffer.numberOfChannels;
        wavesurfer.setHeight( height * WAVE_HEIGHT_FACTOR );

        // console.log('analyser', );

        // NO! THIS IS NOT THE HANDLER CURRENTLY IN USE
        //
        try {
          const gain = wavesurfer.backend.ac.createGain();
          window.g = gain // NO
          gain.gain.value = 0.1;
          g.gain.setValueAtTime(0.2, wavesurfer.backend.ac.currentTime);
          // wavesurfer.backend.setFilters(gain);

          // filters.panner = w.backend.ac.createPanner();
          // window.p = filters.panner;
          // windows.f = filters;
          // console.log('filter', filters);
  
          // panner.setPosition(Math.sin(-45 * (Math.PI / 180)), 0, 0)
          // panner.channelCountMode = 'explicit';
          // wavesurfer.backend.setFilters(filters.panner);
  
        } catch(e) {
          console.error('Error adding filter', e);
        }
        // const lowpass = wavesurfer.backend.ac.createBiquadFilter();
        // wavesurfer.setFilter(lowpass);
        // window.l = lowpass;

        // this.wavesurfer.backend.setPeaks(null); 
        // this.wavesurfer.drawBuffer();

      });

      wavesurfer.on('ready', () => {

        console.log('on READY');

        console.log('duration:', wavesurfer.getDuration() );
        
        console.log('channels:', wavesurfer.backend.buffer.numberOfChannels); // NOPE, it's the buffer, not the file

        const height = window.innerHeight / wavesurfer.backend.buffer.numberOfChannels;
        wavesurfer.setHeight( height * WAVE_HEIGHT_FACTOR );

         try {
          const gain = wavesurfer.backend.ac.createGain();
          window.g = gain;
          gain.gain.value = 1;
          filters.gain = gain;
          // g.gain.setValueAtTime(0.2, wavesurfer.backend.ac.currentTime);
          // wavesurfer.backend.setFilter(gain);

          // const panner = w.backend.ac.createPanner();
          // panner.setPosition(Math.sin(-45 * (Math.PI / 180)), 0, 0)
          // panner.channelCountMode = 'explicit';
          
          filters.panner = w.backend.ac.createStereoPanner();
          window.p = filters.panner;
          filters.panner.pan.value = 0.6;

          // filters.panner = w.backend.ac.createPanner();
          // window.p = filters.panner;
          // filters.panner.pan.value = 0; // this works!
          
          window.f = filters;
          wavesurfer.backend.setFilters([
            filters.gain,
            filters.panner
          ]);

            // THIS WORKS
            // const lowpass = wavesurfer.backend.ac.createBiquadFilter();
            // wavesurfer.backend.setFilter(lowpass);
            // window.l = lowpass;
            
          // console.log('filters', wavesurfer.getFilters());
  
        } catch(e) {
          console.error('Error adding filter', e);
        }

        // wavesurfer.addRegion({
        //   start: 0,
        //   end: wavesurfer.getDuration(),
        //   minLength: 0, 
        //   maxLength: wavesurfer.getDuration(),
        //   loop: true,
        //   color: 'hsla(50, 100%, 30%, 0.5)'
        // });


        if( !this.testMode ){
          wavesurfer.play(); // play once on recording end
          // this.$emit('stateChange', 'playing');
          // console.log( Object.values(wavesurfer.regions.list) );
        } else {
          console.log('ws READY test mode', wavesurfer.regions.list);
          const reg = Object.values(wavesurfer.regions.list)[0];
          reg.play(); // play first region
          // setTimeout( () => this.saveRegion('TEST'), 1000 );
          
          // 3.8s region too long, triggers error
          // 3.1 is too long?
        }


        wavesurfer.on('finish', () => {
          wavesurfer.play();  // hack for looping whole recording
        });


      });  // on 'ready'



      // wavesurfer.on('loading', percent => {
      //   console.log('Loading:', percent);
      // });


      wavesurfer.on('region-click', e => {

        const region = wavesurfer.regions.list[e.id];
        
        if( this.keysHeld.Meta ){
          region.remove();
          return;  
        }

        region.play();
        region.loop = true;
        this.regionIsLooping = true;
        console.log('region click', region, e);
        this.lastRegion = region;
      });

      
      wavesurfer.on('zoom', r => {
        // console.log('zoom', r);
        this.zoomLevel = r; 
      });


      // region-created fires as soon as you start dragging, not when finished
      wavesurfer.on('region-created', r => {
        console.log('region-created', r);
        console.log( Object.values(wavesurfer.regions.list) );
        r.color = '#ff950022';
        r.loop = true;
        r.element.children[0].style.width='1rem';
        r.element.children[0].style.opacity='0.1';
        r.element.children[1].style.width='1rem';
        r.element.children[1].style.opacity='0.1';

        r.data.duration = r.end - r.start;
        r.duplicated = 0;


      }); // on region created



      wavesurfer.on('region-update-end', r => {

        const duration = r.end - r.start;
        if( duration < 0.1 && !r.created ){
          r.remove(); // ignore new regions that are too small
          return;
        }
        
        // New region, update is part of initial create drag
        if( !r.created ){

          // track original length of region (before duplicate events)
          r.data.duration = r.end - r.start;
          r.duplicated = 0;

          r.play();  // play from start on create
        }

        r.created = true; // private use
        r.loop = true;
        this.regionIsLooping = true;

        // console.log('region-update-end', r.start, r.end);
        // console.log( Object.values(wavesurfer.regions.list) );
        window.r = r;
        this.lastRegion = r;


        // if(wavesurfer.getCurrentTime > r.end){
        //   wavesurfer.setCurrentTime(r.start); 
        // }

      }); // on region created


      // region-play
      // region-in
      // region-out

      wavesurfer.on('region-out', r => {
        const region = wavesurfer.regions.list[r.id];
        // wavesurfer.play(region);
        // console.log('region out', region.start);
        if( this.regionIsLooping && this.lastRegion && region.id === this.lastRegion.id ){
          wavesurfer.setCurrentTime(region.start); //TODO: check if region has changed
        }
      });

      // TODO: currently triggers every loop iteration because of the 
      // event-based hack to enforce looping, how to fix?
      // Check if state was just paused?
      // wavesurfer.on('play', e => {
      //   this.stateEmit('playing');
      // });

      // TODO: ALSO triggering every region loop iteration, not sure why?
      // wavesurfer.on('pause', e => {
      //   console.log('ws PAUSE event');
      //   this.stateEmit('paused');
      // });

      window.w   = wavesurfer;
    
    }, // initWavesurfer()




     initFileDragDrop(){

      document.addEventListener("dragover", (event) => {
        event.preventDefault();
      }, false);

      document.addEventListener("drop", (event) => {
        event.preventDefault();
        // d('item', event.dataTransfer.items[0])
        const file =  event.dataTransfer.files[0];

        // Latest
        if (file) {
          const reader = new FileReader();
          reader.onload = (ev) => {
            chunks = [];
            const audio = new Audio();
            console.log('result', ev.target.result);
            // Create a Blob providing as first argument a typed array with the file buffer
            var blob = new window.Blob([new Uint8Array(ev.target.result)]);
            audio.src = URL.createObjectURL(blob);

            // this.waveState = 'cleared';
            wavesurfer.stop();
            wavesurfer.empty();
            wavesurfer.clearRegions();
            wavesurfer.load(audio); 
            // this.waveLoad = event;

            this.hasEverRecorded = true; 
            this.monitorOnStart = false;

            // console.log('loader', loader); // nothing
            // wavesurfer.addRegion({
            //   start: 0,
            //   end: wavesurfer.getDuration(),
            //   minLength: 0, 
            //   maxLength: wavesurfer.getDuration(),
            //   loop: true,
            //   color: 'hsla(50, 100%, 30%, 0.5)'
            // });
            //
            // wavesurfer.loadBlob(blob); 
            // ^^^ Error:
            // Error decoding audiobuffer Main.vue:246:19
            // HTTP “Content-Type” of “text/html” is not supported. Load of media resource http://localhost:5173/[object%20AudioBuffer] failed. localhost:5173
            // Cannot play media. No decoders for requested formats: text/html
          };
          reader.onerror = function (evt) {
              console.error("An error ocurred reading the file: ", evt);
          };

          // reader.readAsDataURL(file);
           reader.readAsArrayBuffer(file);
        }

      }, false); // on drop


    }, // initFileDragDrop()


    initKeyHandlers(){


      document.addEventListener('keydown', (e) => {
        
        this.keysHeld[e.key] = true;
        // console.log('down', e.code);

        switch( e.code ){
        
        // Handled in MAIN
        //
        // case 'Tab':
        //   e.preventDefault();
        //   // if( rec.state === 'recording' ){
        //   if( this.isRecording ){
        //     this.stopRecord();
        //   } else {
        //     this.record();
        //   }
        //   break;

          case 'ArrowLeft': 
            wavesurfer.setCurrentTime( wavesurfer.getCurrentTime() - 0.1 );
            // wavesurfer.play();
            break;

          case 'ArrowRight': 
            wavesurfer.setCurrentTime( wavesurfer.getCurrentTime() + 0.1 );
            // wavesurfer.play();
            break;

          // up/down: Zoom
          case 'ArrowUp': 
            wavesurfer.zoom( Math.min(MAX_ZOOM_LEVEL, this.zoomLevel+50) );
            // wavesurfer.play();
            wavesurfer.params.scrollParent = false;
            break;

          case 'ArrowDown': 
            wavesurfer.zoom( Math.max(MIN_ZOOM_LEVEL, this.zoomLevel-50) );
            // wavesurfer.play();
            wavesurfer.params.scrollParent = false;
            break;

        }

      });


      document.addEventListener('keyup', (e) => {
        this.keysHeld[e.key] = false;
      });


      document.addEventListener('keypress', (e) => {
        switch( e.code ){

        case 'KeyP':
          // let region = Object.values(wavesurfer.regions.list)[0];
          this.lastRegion?.playLoop();  // && this.lasregion.playLoop();
          break;

        case 'KeyS':
          // TODO: save active region/whole buffer
          this.saveRegion('.region');
          break;

        case 'Comma':
          this.playbackRate = Math.max(0.13, this.playbackRate-0.2);
          break;
        case 'Period':
          this.playbackRate = Math.min(2, this.playbackRate+0.2);
          break;
        case 'Slash':
          this.playbackRate = 1;
          break;

        // Loop ends adjust:

        //  [ , ]  - end adjust
        case 'BracketLeft': this.adjustRegion(
          e.shiftKey ? -REGION_RESIZE_MEDIUM : -REGION_RESIZE_SMALL
        );
          break;
        case 'BracketRight': this.adjustRegion(
          e.shiftKey ? REGION_RESIZE_MEDIUM : REGION_RESIZE_SMALL
        );
          break;
          
        //  q, w  - start adjust
        case 'KeyQ': this.adjustRegion(
          e.shiftKey ? -REGION_RESIZE_MEDIUM : -REGION_RESIZE_SMALL,
          'start'
        );
          break;
        case 'KeyW': this.adjustRegion(
          e.shiftKey ? REGION_RESIZE_MEDIUM : REGION_RESIZE_SMALL,
          'start'
        );
          break;

          
          case 'Digit1':
          case 'Digit2':
          case 'Digit3':
          case 'Digit4':
          case 'Digit5':
          case 'Digit6':
          case 'Digit7':
          case 'Digit8':
          case 'Digit9':
            this.extendRegion(+e.key);
            break;

          case 'Digit0':
            wavesurfer.zoom(100);
            wavesurfer.params.scrollParent = false;
            break;


        default:
          console.log('Key not handled', e.code, e);          
        }
      });


    }, // initKeyHandlers()


    adjustRegion(amt, start=undefined){
      if( !this.lastRegion ) return;
      this.lastRegion.onResize(amt, start); 
    },   


    extendRegion( mult ){
      console.log('%cextendRegion()', 'color:red; font-weight:bold', mult);
      if( !this.lastRegion ) return;

      const r = this.lastRegion;

      if( mult === 1){
        // special case: reset to original length
        const timeSub = (r.end - r.start) - r.data.duration;
        r.onResize(-timeSub);
        r.data.duplicated = 0;
        return;
      }

      const timeAdded = r.data.duration * (mult - 1);
      r.onResize( timeAdded );
      r.data.duplicated = mult;
      
      console.log('dur', r.data.duration);

    }, // extendRegion()



    handleWaveClick(e){
      // d(e, e.originalTarget.nodeName)
      if(e.originalTarget.nodeName !== 'REGION'){
        this.regionIsLooping = false;
      }
    },


    handleMiddleClick(e){
      d(e, e.originalTarget.nodeName)
      if(e.originalTarget.nodeName !== 'REGION'){
        // this.regionIsLooping = false;
        console.log('middle clicl, ');
      }
    },


    handleScrollZoom(e){
      // console.log('handleScrollZoom');    
      // d(e);
      wavesurfer.zoom( 
        Math.max(MIN_ZOOM_LEVEL, 
          Math.min(MAX_ZOOM_LEVEL, this.zoomLevel - e.deltaY)
        )
      );
      wavesurfer.params.scrollParent = false;
      //  wavesurfer.zoom( Math.max(100, this.zoomLevel-50) );

    },


    // https://stackoverflow.com/a/66799384 - offlineaudiocontext??
    saveRegion(nameExt=''){
      console.log('%csaveRegion()', 'color: green; font-weight: bold;');
      if(!this.lastRegion) return;
      
      // if( !this.testMode ){
      //   const fullWave =  bufferToWave(wavesurfer.backend.buffer, 0, wavesurfer.backend.buffer.length);
      //   saveFile(fullWave, dateString() + nameExt + '.full.wav');
      // }

      const slice = bufferSlice(
        wavesurfer.backend.buffer, 
        wavesurfer.backend.ac, 
        this.lastRegion.start, 
        this.lastRegion.end 
      );

      const duration = (this.lastRegion.end - this.lastRegion.start).toFixed(2);

      const regionWave =  bufferToWave(slice, 0, slice.length);
      saveFile(regionWave, dateString() + nameExt + '-' + duration + 'sec.wav');

    }, // saveRegion()





    // called by parent to trigger child player action
    triggerAction(action, ...args){
      console.log('triggerAction()', action);
      switch(action){
        
      case 'playPause':
        wavesurfer.playPause();
        break;
      
      case 'load':
        wavesurfer.load( args[0] );
        break;
      
      

      case 'clear':
        wavesurfer.stop();
        wavesurfer.empty();
        wavesurfer.clearRegions();
        wavesurfer.setPlaybackRate(1);
        // this.playbackRate = 1;
        break;
      
      default: 
        console.log('%cUNHANDLED player action:', state);
      }
    }, // triggerAction()


    // to send updates to parent
    stateEmit(name, ...args){
      this.$emit('stateChange', name, ...args);
    },



  }, // methods

}; // Vue component




// Adapted from https://miguelmota.com/bytes/slice-audiobuffer/
function bufferSlice(buffer, audioContext, begin, end){
  if (begin < 0) {
    throw new RangeError('begin time must be greater than 0');
  }
  if (end > duration) {
    throw new RangeError('end time must be less than or equal to ' + duration);
  }

  var duration = buffer.duration;
  var channels = buffer.numberOfChannels;
  var rate = buffer.sampleRate;
  var startOffset = rate * begin;
  var endOffset = rate * end;
  var frameCount = endOffset - startOffset;
  
  var newArrayBuffer = audioContext.createBuffer(channels, frameCount, rate);
  var anotherArray = new Float32Array(frameCount);
  var offset = 0;

  for (var channel = 0; channel < channels; channel++) {
    buffer.copyFromChannel(anotherArray, channel, startOffset);
    newArrayBuffer.copyToChannel(anotherArray, channel, offset);
  }

  return newArrayBuffer;
}



// https://stackoverflow.com/a/62260599
// (C) Ken Fyrstenberg / MIT license
// TODO: format is hardcoded 16bit 44khz?
function bufferToWave(abuffer, offset, len) {

  var numOfChan = abuffer.numberOfChannels,
      length = len * numOfChan * 2 + 44,
      buffer = new ArrayBuffer(length),
      view = new DataView(buffer),
      channels = [], i, sample,
      pos = 0;

  console.log({view});

  // write WAVE header
  setUint32(0x46464952);                         // "RIFF"
  setUint32(length - 8);                         // file length - 8
  setUint32(0x45564157);                         // "WAVE"

  setUint32(0x20746d66);                         // "fmt " chunk
  setUint32(16);                                 // length = 16
  setUint16(1);                                  // PCM (uncompressed)
  setUint16(numOfChan);
  setUint32(abuffer.sampleRate);
  setUint32(abuffer.sampleRate * 2 * numOfChan); // avg. bytes/sec
  setUint16(numOfChan * 2);                      // block-align
  setUint16(16);                                 // 16-bit (hardcoded in this demo)

  setUint32(0x61746164);                         // "data" - chunk
  setUint32(length - pos - 4);                   // chunk length

  // write interleaved data
  for(i = 0; i < abuffer.numberOfChannels; i++)
    channels.push(abuffer.getChannelData(i));

  while(pos < length) {
    for(i = 0; i < numOfChan; i++) {             // interleave channels
      sample = Math.max(-1, Math.min(1, channels[i][offset])); // clamp
      sample = (0.5 + sample < 0 ? sample * 32768 : sample * 32767)|0; // scale to 16-bit signed int
      view.setInt16(pos, sample, true);          // update data chunk
      pos += 2;
    }
    offset++                                     // next source sample
  }

  // create Blob
  return (URL || webkitURL).createObjectURL(new Blob([buffer], {type: "audio/wav"}));

  function setUint16(data) {
    view.setUint16(pos, data, true);
    pos += 2;
  }

  function setUint32(data) {
    view.setUint32(pos, data, true);
    pos += 4;
  }
}

// https://stackoverflow.com/a/48968694
function saveFile(fileURL, filename) {
  if (window.navigator.msSaveOrOpenBlob) {
    window.navigator.msSaveOrOpenBlob(blob, filename);
  } else {
    const a = document.createElement('a');
    document.body.appendChild(a);
    // const url = window.URL.createObjectURL(blob);
    a.href = fileURL;
    a.download = filename;
    a.click();
    setTimeout(() => {
      window.URL.revokeObjectURL(fileURL);
      document.body.removeChild(a);
    }, 0)
  }
}


// https://stackoverflow.com/questions/10645994/how-to-format-a-utc-date-as-a-yyyy-mm-dd-hhmmss-string-using-nodejs
// https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Intl/DateTimeFormat/DateTimeFormat#options
function dateString(){
  // return new Date().toISOString().replace('T', '_').replace(':', '.').replace(/\..+/, '');
  return new Date()
    .toLocaleString('default', { dateStyle: 'short', timeStyle: 'medium' })
    .replaceAll('/', '-') // ugh
    .replace(', ', '_')
    .replaceAll(':', '.')
    .replaceAll(' ', '');
}



function processAudioBuffer(buf){
 for (let channel = 0; channel < buf.numberOfChannels; channel++) {
    const inputData = buf.getChannelData(channel);
    // const outputData = outputBuffer.getChannelData(channel);
    // Loop through the 4096 samples
    for (let sample = 0; sample < buf.length; sample++) {
      // make output equal to the same as the input
      // outputData[sample] = inputData[sample];
      // add noise to each output sample
      // outputData[sample] += ((Math.random() * 2) - 1) * 0.2;
      
      if( Math.abs(inputData[sample]) > 0.3 ){
        console.log('data', inputData[sample]);
      }


    }
  }

}


</script>

<style>

</style>