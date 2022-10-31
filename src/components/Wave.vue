<template>
  <div>
    <!-- action: {{ waveStore.status }} -->
    <div id="waveform" ref="waveform" 
      @wheel="handleScrollZoom" 
      @click="handleWaveClick"
      @auxclick="handleMiddleClick"
      :class="isRecording && 'recording'"
    />
  </div>
</template>

<script>

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

// import {useWavePlayerStore} from '@/stores/wavePlayer.js';


let wavesurfer = null;
const filters = {};


export default {
  name: 'Wave',
  // components: { Slider },
  props: [ 'inputDeviceId', 'channelCount', 'state', 'load', 'bus' ],
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
        container: this.$refs.waveform, // << slight FOUC  
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
        // autocenter: true,

        responsive: true,

        // ISSUE: with WebAudio, 'setPlaybackRate'  actually changes rate (inc. pitch)
        // instead of a nice time stretch...
        backend: 'WebAudio',  // wavesurfer.backend  ??? MediaElement / WebAudio
        plugins: [
            RegionsPlugin.create({
                dragSelection: {
                    slop: 5 // 5
                }
            })  // RegionsPlugin.create()
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

      wavesurfer.on('pause', e => {
        this.stateEmit('paused');
      });

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

        // for (let i=0; i<items.length; i++) {
        //   let item = items[i].webkitGetAsEntry(); // FF only?
        //   if (item) {
        //       // scanFiles(item, listing);
        //       d(item)
        //       // console.log(item.file());
        //
        //       item.file(file => {
        //         let reader = new FileReader();
        //         console.log('reader', file);
        //         // wavesurfer.load(file);
        //
        //         reader.onload = (ev) => {
        //
        // FileReader.readAsArrayBuffer()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains an ArrayBuffer representing the file's data.
        // FileReader.readAsBinaryString()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains the raw binary data from the file as a string.
        // FileReader.readAsDataURL()
        // Starts reading the contents of the specified Blob, once finished, the result attribute contains a data: URL representing the file's data.
        // FileReader.readAsText()
        // 
        //           // successCallback(reader.result);
        //           console.log('SUCCESS', reader.readyState);
        //           const blob = new Blob([new Uint8Array(reader.result)]);
        //           wavesurfer.loadBlob(blob);
        //           // console.log('SUCCESS', reader.result);
        //           // const blob = new Blob(reader.result);
        //           // wavesurfer.loadBlob(reader.result);
        // 
        //           // const audio = new Audio();
        //           // audio.src = URL.createObjectURL(blob);
        //           // wavesurferAdd(audio);
        //           // chunks = [];
        //         };
        //
        //         reader.onerror = () => {
        //           // errorCallback(reader.error);
        //           console.log('ERR', reader.error);
        //         }
        //
        //           // reader.readAsText(file);
        //           // reader.readAsBinaryString(file);
        //           reader.readAsArrayBuffer(file);
        //
        //       }, console.warn); // open each file dropped
        //   }
        // }


      }, false); // on drop


    }, // initFileDragDrop()


    initKeyHandlers(){


      document.addEventListener('keydown', (e) => {
        
        this.keysHeld[e.key] = true;
        // console.log('down', e.code);

        switch( e.code ){
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



      // document.addEventListener('keypress', (e) => {
      //   switch( e.code ){
      //   case 'Space':
      //     this.handleSpacebarPress(e);
      //     break;

      //   case 'KeyP':
      //     // let region = Object.values(wavesurfer.regions.list)[0];
      //     this.lastRegion?.playLoop();  // && this.lasregion.playLoop();
      //     break;

      //   case 'KeyR':
      //     if( this.isRecording ) {
      //       this.stopRecord();
      //     } else {
      //       if( this.isWaitingToRecord ){
      //         this.stopRecord();
      //       } else {
      //         this.recordArm();
      //       }
      //     }
      //     break;

      //   case 'KeyS':
      //     // TODO: save active region/whole buffer
      //     this.saveRegion();
      //     break;

      //   case 'Comma':
      //     this.playbackRate = Math.max(0.13, this.playbackRate-0.2);
      //     break;
      //   case 'Period':
      //     this.playbackRate = Math.min(2, this.playbackRate+0.2);
      //     break;
      //   case 'Slash':
      //     this.playbackRate = 1;
      //     break;

      //     // Loop ends adjust:

      //     //  [ , ]  - end adjust
      //     case 'BracketLeft': this.adjustRegion(
      //       e.shiftKey ? -REGION_RESIZE_MEDIUM : -REGION_RESIZE_SMALL
      //     );
      //       break;
      //     case 'BracketRight': this.adjustRegion(
      //       e.shiftKey ? REGION_RESIZE_MEDIUM : REGION_RESIZE_SMALL
      //     );
      //       break;
            
      //     //  q, w  - start adjust
      //     case 'KeyQ': this.adjustRegion(
      //       e.shiftKey ? -REGION_RESIZE_MEDIUM : -REGION_RESIZE_SMALL,
      //       'start'
      //     );
      //       break;
      //     case 'KeyW': this.adjustRegion(
      //       e.shiftKey ? REGION_RESIZE_MEDIUM : REGION_RESIZE_SMALL,
      //       'start'
      //     );
      //       break;

          
      //     case 'Digit1':
      //     case 'Digit2':
      //     case 'Digit3':
      //     case 'Digit4':
      //     case 'Digit5':
      //     case 'Digit6':
      //     case 'Digit7':
      //     case 'Digit8':
      //     case 'Digit9':
      //       this.extendRegion(+e.key);
      //       break;

      //     case 'Digit0':
      //       wavesurfer.zoom(100);
      //       wavesurfer.params.scrollParent = false;
      //       break;


      //   default:
      //     console.log('Key not handled', e.code, e);          
      //   }
      // });


    }, // initKeyHandlers()



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

}
</script>

<style>

</style>