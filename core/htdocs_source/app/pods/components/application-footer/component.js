import Component from '@glimmer/component';
import { inject as service } from '@ember/service';

export default class OxiApplicationFooter extends Component {
    @service('oxi-config') config;
}
