/*
 * Base class for all batch apex based steps
 *
 * @author: Iskander Mukhamedgaliyev
 */
public with sharing abstract class ClusterBatchBase implements Database.Batchable<sObject>, Database.Stateful, ClusterAlgorithmStep {
    public ClusterAlgorithmRunner runner;
    private Boolean hadErrorsDuringProcessing;
    private String lastProcessingError;
    public static Logger log = LogFactory.getLogger();

    public ClusterBatchBase() {
    }   
    
    public virtual void init(ClusterAlgorithmRunner runner) {
        this.runner = runner;
        ClusterJobState jobState = this.runner.getJobState();
        jobState = this.runner.getJobState();
        this.hadErrorsDuringProcessing = false;
        this.lastProcessingError = '';
    }

    public virtual Integer getBatchSize() {
        //If model has long text fields we need to reduce the batch size to avoid hitting heap/CPU limits        
        ClusterModelWrapper model = this.runner.getJobState().model;
        Boolean hasLongText = model.hasLongTextFields();
        return hasLongText ? ClusterConstants.getLongTextBatchSize() : ClusterConstants.getBatchSize();
    }

    public virtual void run(){
        Integer batchSize = Test.isRunningTest() ? ClusterConstants.TEST_BATCH_SIZE : this.getBatchSize();
        ClusterJobState jobState = this.runner.getJobState();
        jobState.currentJobId = Database.executeBatch(this, batchSize);
        log.debug('Started batch job: ' + jobState.currentJobId);
    }

    public virtual void done(){
        runner.processNextSteps();
    }

    public Boolean isAsync(){
        return true;
    }   

    protected abstract Database.QueryLocator getBatchQueryLocator();

    public virtual Database.QueryLocator start(Database.BatchableContext bc) {
        Database.QueryLocator query = this.getBatchQueryLocator();
        log.debug('Entering batch start, processing soql query: ' + query.getQuery());
        return query;
    }

    public virtual void execute(Database.BatchableContext bc, List<SObject> scope) {
        log.debug('Entering execute, processing ' + scope.size() + ' records');
        ClusterJobState jobState = this.runner.getJobState();
        try {
            this.processRecords(bc, scope);
        }
        catch (Exception ex) {
            this.hadErrorsDuringProcessing = true;
            this.lastProcessingError = ex.getMessage();
            log.error('Exception caught while processing ' + scope.size() + ' records', ex);
            ClusterJobManager.saveJobState(jobState, ClusterConstants.JOBSTATUS_FAILED, ex.getMessage());
            throw ex; //TODO: this will probably rollback everything, maybe abort job instead
        }
        log.debug('Finished processing the chunk, current heap size: ' + Limits.getHeapSize());
    }

    public abstract void processRecords(Database.BatchableContext bc, List<SObject> scope);

    public virtual void finish(Database.BatchableContext bc){
        ClusterJobState jobState = this.runner.getJobState();
        //TODO: some batches might fail due to governor limit errors, such exceptions can't be caught in Apex. We need to check the job status here
        try {
            if (bc != null) {
                try {
                    List<SObject> jobs = Database.query('SELECT ApexClassId,CompletedDate,CreatedById,CreatedDate,ExtendedStatus,Id,JobItemsProcessed,JobType,LastProcessed,LastProcessedOffset,MethodName,NumberOfErrors,ParentJobId,Status,TotalJobItems FROM AsyncApexJob WHERE Id=\'' 
                        + String.escapeSingleQuotes(bc.getJobId()) + '\'');
                    if (jobs.size() == 1) {
                        SObject aajob = jobs.get(0);
                        if (Integer.valueOf(aajob.get('NumberOfErrors')) > 0) {
                            throw new ClusterException('Some or all batches in batch job ' + aaJob.get('Id') + ' failed with status: ' + aajob.get('ExtendedStatus') + ', number of errors: ' + aajob.get('NumberOfErrors')); 
                        }
                    }
                }
                catch (ClusterException ex) {
                    //Re-throw ClusterException
                    throw ex;
                }
                catch (Exception ex) {
                    //AsyncApexJob might not be accessible for some reason (Professional org?)
                    //Just log the error and continue
                    log.error('Failed to get async job status', ex);
                }
            }
            if (this.hadErrorsDuringProcessing) {
                throw new ClusterException('The following errors reported during processing: ' + this.lastProcessingError);
            }
            ClusterJobManager.saveJobState(jobState, ClusterConstants.JOBSTATUS_IN_PROGRESS, '');
            this.done();
            log.debug('Finishing batch job: ' + jobState.currentJobId);
            log.debug('Current heap size: ' + Limits.getHeapSize());
        }
        catch (Exception ex) {
            String logMessage = 'Exception caught during finalization of step ' + jobState.currentAlgorithmStep;
            log.error(logMessage, ex);
            ClusterJobManager.saveJobState(jobState, ClusterConstants.JOBSTATUS_FAILED, logMessage + ': ' + ex.getMessage());
        }
    }    

}
